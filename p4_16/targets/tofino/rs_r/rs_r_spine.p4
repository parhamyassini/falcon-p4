#include <core.p4>
#include <tna.p4>

#include "../common/headers.p4"
#include "../common/util.p4"
#include "../headers.p4"


// Hardcoded ID of each switch, needed for letting the switches to communicate with each other
#define SWITCH_ID 16w100 

control SpineIngress(
        inout horus_header_t hdr,
        inout horus_metadata_t horus_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md) {

    Random<bit<16>>() random_ds_id;

    /********  Action/table decelarations *********/
    action _drop() {
        ig_intr_dprsr_md.drop_ctl = 0x1; // Drop packet.
    }

    action get_leaf_start_idx () {
        horus_md.cluster_ds_start_idx = (bit <16>) (hdr.horus.cluster_id * MAX_LEAFS_PER_CLUSTER);
    }
    

    //////// 
    action gen_random_leaf_index_16() {
        horus_md.random_ds_index_1 = (bit<16>) random_ds_id.get();
        horus_md.random_ds_index_2 = (bit<16>) random_ds_id.get();

    }
    action adjust_random_leaf_index_8() {
        horus_md.random_ds_index_1 = horus_md.random_ds_index_1 >> 8;
        horus_md.random_ds_index_2 = horus_md.random_ds_index_2 >> 8;
    }

    action adjust_random_leaf_index_4() {
        horus_md.random_ds_index_1 = horus_md.random_ds_index_1 >> 12;
        horus_md.random_ds_index_2 = horus_md.random_ds_index_2 >> 12;
    }

    action adjust_random_leaf_index_2() {
        horus_md.random_ds_index_1 = horus_md.random_ds_index_1 >> 14;
        horus_md.random_ds_index_2 = horus_md.random_ds_index_2 >> 14;
    }

    action adjust_random_leaf_index_1() {
        horus_md.random_ds_index_1 = horus_md.random_ds_index_1 >> 15;
        horus_md.random_ds_index_2 = horus_md.random_ds_index_2 >> 15;
    }

    table adjust_random_range_sq_leafs { // Adjust the random generated number (16 bit) based on number of available queue len signals
        key = {
            horus_md.cluster_num_valid_queue_signals: exact; 
        }
        actions = {
            adjust_random_leaf_index_8(); // == 8
            adjust_random_leaf_index_4(); // == 4
            adjust_random_leaf_index_2(); // == 2
            adjust_random_leaf_index_1(); // == 1
            NoAction; // == 16
        }
        size = 16;
        default_action = NoAction;
    }
    
    action act_forward_horus(PortId_t port) {
        ig_intr_tm_md.ucast_egress_port = port;
        // TESTBEDONLY: comment the line below when no need for emulating multiple leaf schedulers using one switch. 
        // See Horus spine comments for details.
        //hdr.horus.cluster_id = hdr.horus.dst_id; // We use different cluster ids for each virtual leaf switch 
    }
    table forward_horus_switch_dst {
        key = {
            hdr.horus.dst_id: exact;
        }
        actions = {
            act_forward_horus;
            NoAction;
        }
        size = HDR_SRC_ID_SIZE;
        default_action = NoAction;
    }
    
    action act_get_cluster_num_valid_leafs(bit<16> num_leafs) {
        horus_md.cluster_num_valid_queue_signals = num_leafs;
    }
    table get_cluster_num_valid_leafs { // TODO: fix typo: Leaves !
        key = {
            hdr.horus.cluster_id : exact;
        }
        actions = {
            act_get_cluster_num_valid_leafs;
            NoAction;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = NoAction;
    }
    
    
    action act_get_rand_leaf_id_1(bit <16> leaf_id){
        horus_md.random_id_1 = leaf_id;
    }
    table get_rand_leaf_id_1 {
        key = {
            horus_md.random_ds_index_1: exact;
            hdr.horus.cluster_id: exact;
        }
        actions = {
            act_get_rand_leaf_id_1();
            NoAction;
        }
        size = 16;
        default_action = NoAction;
    }
    
    /********  Control block logic *********/
    apply {
        if (hdr.horus.isValid()) {  // Horus packet
           
        if (hdr.horus.dst_id == SWITCH_ID && hdr.horus.pkt_type == PKT_TYPE_NEW_TASK) { // If this packet is destined for this spine do horus processing ot. its just an intransit packet we need to forward on correct port
            // TESTBEDONLY: See horus spine comments. comment the line below when no need for emulating multiple leaf schedulers.
            hdr.horus.cluster_id = 0;
            @stage(1) {
                get_leaf_start_idx ();
                get_cluster_num_valid_leafs.apply();
                gen_random_leaf_index_16();
            }

            @stage(2) {
                adjust_random_range_sq_leafs.apply(); //  select a random leaf index
            }

            @stage(3) {
                get_rand_leaf_id_1.apply(); // Read the leaf ID associated with generated random index
            }

            @stage(4) {
                hdr.horus.dst_id = horus_md.random_id_1;

            }
            
        }
        hdr.horus.src_id = SWITCH_ID;
        forward_horus_switch_dst.apply();
            
        } else if (hdr.ipv4.isValid()) { // Regular switching procedure
            // TODO: Not ported the ip matching tables for now
            _drop();
        } else {
            _drop();
        }
    }
}

control SpineIngressDeparser(
        packet_out pkt,
        inout horus_header_t hdr,
        in horus_metadata_t horus_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {
         
    Mirror() mirror;
    Resubmit() resubmit;

    apply {
        if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_NEW_TASK) {
            mirror.emit<empty_t>((MirrorId_t) horus_md.mirror_dst_id, {}); 
        }  
        if (ig_intr_dprsr_md.resubmit_type == RESUBMIT_TYPE_NEW_TASK) {
            resubmit.emit(horus_md.task_resub_hdr);
        } 
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.udp);
        pkt.emit(hdr.horus);
    }
}

// Empty egress parser/control blocks
parser SpineEgressParser(
        packet_in pkt,
        out horus_header_t hdr,
        out eg_metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        pkt.extract(eg_intr_md);
        transition accept;
    }
}

control SpineEgressDeparser(
        packet_out pkt,
        inout horus_header_t hdr,
        in eg_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md) {
    apply {}
}

control SpineEgress(
        inout horus_header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
        inout egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_intr_oport_md) {
    apply {}
}
