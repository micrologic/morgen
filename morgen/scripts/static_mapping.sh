#!/bin/bash

OUTDIR="static_mapping"

for graph in mesh fla thermal eco audi copaper livejournal kkt amazon rmat1 rmat2 random1 random2
do


	for i in 1 2 4 8 16 32
	do
		echo ./bin/test $graph queue  --group_size=$i --block_size=256 
		./bin/test $graph queue  --group_size=$i --block_size=256  | grep -E 'Time' >> ./$OUTDIR_$graph.out
	done
done