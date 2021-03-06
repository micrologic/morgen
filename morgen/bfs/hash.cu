
/*
 *   The breadth-first search algorithm
 *
 *   Copyright (C) 2013-2014 by
 *   Cheng Yichao        onesuperclark@gmail.com
 *
 *   This program is free software; you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation; either version 2 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 */


#pragma once

#include <morgen/utils/macros.cuh>
#include <morgen/utils/timing.cuh>
#include <morgen/utils/list.cuh>
#include <morgen/workset/hash.cuh>

#include <cuda_runtime_api.h>


namespace morgen {

namespace bfs {


/**
 * This is a fixed thread-mapping kernel for hashe-based workset
 * The workset of current level is processed in one kernal launch
 */
template<typename VertexId, typename SizeT, typename Value>
__global__ void
BFSKernel_hash_thread_map(
  SizeT     *row_offsets,
  VertexId  *column_indices,
  VertexId  *workset_from,
  SizeT     slot_num_from,
  SizeT     *slot_offsets_from,
  SizeT     *slot_sizes_from,
  SizeT     *workset_to,
  SizeT     slot_num_to,
  SizeT     *slot_offsets_to,
  VertexId  *slot_sizes_to,
  Value     *levels,
  Value     curLevel,
  int       *visited)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Initially, clean the workset to empty(each slot counter = 0)
    if (tid < slot_num_to) {
        slot_sizes_to[tid] = 0;
    }

    __syncthreads();


    // tid  0 1 2 3 4 5  <- accord threads num with the logical size   
    //  0   a b c d e f
    //  1   g h i j
    //  2   k l m n o
    //  3   p q
    for (int i = 0; i < slot_num_from; i++) {

        if (tid < slot_sizes_from[i]) {

            VertexId outNode = workset_from[slot_offsets_from[i] + tid];
            SizeT outEdgeFirst = row_offsets[outNode];
            SizeT outEdgeLast = row_offsets[outNode+1];

            // serial expansion
            for (SizeT edge = outEdgeFirst; edge < outEdgeLast; edge++) {

                VertexId inNode = column_indices[edge];

                // resolve concurrent discovery through atomical operations
                int old = atomicExch( (int*)&visited[inNode], 1 );

                if (old == 0) { 

                    levels[inNode] = curLevel + 1;

                    // hash the pos by inNode id
                    int hash = inNode % slot_num_to;

                    // exclusively get the writing position within the slot
                    SizeT pos= atomicAdd( (SizeT*) &(slot_sizes_to[hash]), 1 );
                    workset_to[slot_offsets_to[hash] + pos] = inNode;
                }
            }   
        }
    }   
}





template<typename VertexId, typename SizeT, typename Value>
void BFSGraph_gpu_hash(
    const graph::CsrGraph<VertexId, SizeT, Value> &g, 
    VertexId source, 
    int slots,
    bool instrument = false)
{

    if (slots > 0) {
        printf("Slots = %d\n", slots);
    }
    else {
        printf("Slots should be a positive number\n");
        return;
    }

    // To make better use of the workset, we create two.
    // Instead of creating a new one everytime in each BFS level,
    // we just expand vertices from one to another

    workset::Hash<VertexId, SizeT, Value>  workset[] = {
        workset::Hash<VertexId, SizeT, Value>(g.n, slots),
        workset::Hash<VertexId, SizeT, Value>(g.n, slots),
    };

    // use to select between two worksets
    // src:  workset[selector]
    // dest: workset[selector ^ 1]
    int selector = 0;

    // Initalize auxiliary list
    util::List<Value, SizeT> levels(g.n);
    levels.all_to((Value) MORGEN_INF);


    // visitation list: 0 for unvisited
    util::List<int, SizeT> visited(g.n);
    visited.all_to(0);


    // traverse from source node
    workset[0].insert(source % slots, source);   
    levels.set(source, 0);
    visited.set(source, 1);

    SizeT worksetSize = 1;
    SizeT lastWorksetSize = 0;
    SizeT actualWorksetSize = 1; 
    SizeT lastActualWorksetSize = 0;

    Value curLevel = 0;

    // kernel configuration
    int blockNum = 16;
    int blockSize = 256;

    printf("GPU hashed bfs starts... \n");  
    if (instrument)
        printf("level\tslot_size\tfrontier_size\tratio\ttime\n");

    float total_millis = 0.0;

    while (worksetSize > 0) {

        lastWorksetSize = worksetSize;
        lastActualWorksetSize = actualWorksetSize;

        // In hashed version,  the worksetSize is the logical size
        // of the hash table(smallest among the slot sizes)
        blockNum = (worksetSize % blockSize == 0 ? 
            worksetSize / blockSize :
            worksetSize / blockSize + 1);


        // kick off timer first
        util::GpuTimer gpu_timer;
        gpu_timer.start();


            // call kernel with device pointers
        BFSKernel_hash_thread_map<<<blockNum, blockSize>>>(
            g.d_row_offsets,
            g.d_column_indices,
            workset[selector].d_elems,
            workset[selector].slot_num,
            workset[selector].d_slot_offsets,
            workset[selector].d_slot_sizes,                                    
            workset[selector ^ 1].d_elems,
            workset[selector ^ 1].slot_num,
            workset[selector ^ 1].d_slot_offsets,
            workset[selector ^ 1].d_slot_sizes,
            levels.d_elems,
            curLevel,     
            visited.d_elems);

        if (util::handleError(cudaThreadSynchronize(), "BFSKernel failed ", __FILE__, __LINE__)) break;

        worksetSize = workset[selector ^ 1].max_slot_size();
        actualWorksetSize = workset[selector ^ 1].sum_slot_size();


        // timer end
        gpu_timer.stop();
        float mapping_efficiency = (float) lastActualWorksetSize / (lastWorksetSize * slots);
        total_millis += gpu_timer.elapsedMillis();
        if (instrument) printf("%d\t%d\t%d\t%.3f\t%f\n", curLevel, lastWorksetSize, lastActualWorksetSize, mapping_efficiency, gpu_timer.elapsedMillis());

        curLevel += 1;
        selector = selector ^ 1;
    }
    
    printf("GPU hashed bfs terminates\n");
    float billion_edges_per_second = (float)g.m / total_millis / 1000000.0;
    printf("Time(s):\t%f\nSpeed(BE/s):\t%f\n", total_millis / 1000.0, billion_edges_per_second);

    levels.print_log();

    levels.del();
    visited.del();
    workset[0].del();
    workset[1].del();
    
}


} // BFS
} // Morgen