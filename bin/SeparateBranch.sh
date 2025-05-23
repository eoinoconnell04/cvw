#!/bin/bash

###########################################
## Written: rose@rosethompson.net
## Created: 12 March 2023
## Modified: 15 April 2025 jcarlin@hmc.edu
##
## Purpose: Converts a single branch.log containing multiple benchmark branch outcomes into
##          separate files, one for each program.
## Input:   branch log file generated by modelsim
## output:  outputs to directory branch a collection of files with the branch outcomes
##          separated by benchmark application.  Example names are aha-mot64bd_sizeopt_speed_branch.log
##
## A component of the CORE-V-WALLY configurable RISC-V project.
## https://github.com/openhwgroup/cvw
##
## Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
##
## SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
##
## Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
## except in compliance with the License, or, at your option, the Apache License version 2.0. You 
## may obtain a copy of the License at
##
## https:##solderpad.org/licenses/SHL-2.1/
##
## Unless required by applicable law or agreed to in writing, any work distributed under the 
## License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
## either express or implied. See the License for the specific language governing permissions 
## and limitations under the License.
################################################################################################

File="$1"
TrainLineNumbers=$(grep -n "TRAIN" "$File" | awk -NF ':' '{print $1}')
Name=$(grep -n "BEGIN" "$File" | awk -NF '/' '{print $7_$5}')
EndLineNumbers=$(grep -n "END" "$File" | awk -NF ':' '{print $1}')

echo Name: "$Name"
echo TrainLineNumbers: "$TrainLineNumbers"
echo EndLineNumbers: "$EndLineNumbers"

mapfile -t NameArray <<< "$Name"
mapfile -t TrainLineNumberArray <<< "$TrainLineNumbers"
mapfile -t EndLineNumberArray <<< "$EndLineNumbers"

OutputPath=${File%%.*}
mkdir -p "$OutputPath"
Length=${#EndLineNumberArray[@]}
for i in $(seq 0 1 $((Length-1)))
do
    CurrName=${NameArray[$i]}
    CurrTrain=$((${TrainLineNumberArray[$i]}+1))
    CurrEnd=$((${EndLineNumberArray[$i]}-1))
    echo "${CurrName}", "${CurrTrain}", "${CurrEnd}"
    sed -n "${CurrTrain},${CurrEnd}p" "$File" > "${OutputPath}/${CurrName}_${File}"
done
