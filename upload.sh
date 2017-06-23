#!/bin/sh

SCENARIO=${1:-one_to_one.erl}
AMOC_PORTS=( 4000 4001 4002 )

for PORT in ${AMOC_PORTS[@]}
do
    http POST "localhost:$PORT/scenarios" scenario=one_to_one module_source="$(cat $SCENARIO)"
done
