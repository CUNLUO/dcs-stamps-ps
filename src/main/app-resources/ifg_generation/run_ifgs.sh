#! /bin/bash
mode=$1
#set -x 

# source the ciop functions (e.g. ciop-log)
[ "${mode}" != "test" ] && source ${ciop_job_include}

# source extra functions
source ${_CIOP_APPLICATION_PATH}/lib/stamps-helpers.sh

# source StaMPS
source /opt/StaMPS_v3.3b1/StaMPS_CONFIG.bash

# source sar helpers and functions
set_env

#--------------------------------
#       2) Error Handling       
#--------------------------------

# define the exit codes
SUCCESS=0
ERR_MASTER_RETRIEVE=7
ERR_UNTAR_MASTER=9
ERR_SLC_RETRIEVE=11


# add a trap to exit gracefully
cleanExit() {
local retval=$?
local msg
msg=""
case "${retval}" in
${SUCCESS}) msg="Processing successfully concluded";;
${ERR_MASTER_RETRIEVE}) msg="";;
${ERR_UNTAR_MASTER}) msg="";;
${ERR_SLC_RETRIEVE}) msg="";;
${ERR_STEP_ORBIT}) msg="";;
${ERR_MASTER_RETRIEVE}) msg="";;
${ERR_MASTER_RETRIEVE}) msg="";;
${ERR_MASTER_RETRIEVE}) msg="";;
esac
[ "${retval}" != "0" ] && ciop-log "ERROR" \
"Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
#[ -n "${TMPDIR}" ] && rm -rf ${TMPDIR}
[ -n "${TMPDIR}" ] && chmod -R 777 $TMPDIR
[ "${mode}" == "test" ] && return ${retval} || exit ${retval}
}
trap cleanExit EXIT

main() {
local res
master_date=""

while read line; do

	ciop-log "INFO" "Processing input: $line"
        IFS=',' read -r insar_master slc_folders dem <<< "$line"
	ciop-log "DEBUG" "1:$insar_master 2:$slc_folders 3:$dem"

	if [ ! -d "${PROCESS}/INSAR_${master_date}/" ]; then
	
		ciop-copy -O ${PROCESS} ${insar_master}
		[ $? -ne 0 ] && return ${ERR_MASTER_RETRIEVE}
		
		master_date=`basename ${PROCESS}/I* | cut -c 7-14` 	
		ciop-log "INFO" "Final Master Date: $master_date"
		
	fi

	if [ ! -e "${TMPDIR}/DEM/final_dem.dem" ]; then

	ciop-copy -O ${TMPDIR} ${dem}
	[ $? -ne 0 ] && return ${ERR_DEM_RETRIEVE}

	fi

	ciop-copy -O ${SLC} ${slc_folders}
	[ $? -ne 0 ] && return ${ERR_SLC_RETRIEVE}
	
	sensing_date=`basename ${slc_folders} | cut -c 1-8`
	
	ciop-log "INFO" "Processing scene of $sensing_date"
	
	if [ $sensing_date != $master_date ];then
		
		# 	go to master folder
		cd ${PROCESS}/INSAR_${master_date}

		# 	adjust the original file paths for the current node	       
		sed -i "61s|Data_output_file:.*|Data_output_file:\t${PROCESS}/INSAR_${master_date}/${master_date}\_crop.slc|" master.res
		sed -i "s|DEM source file:.*|DEM source file:\t	${TMPDIR}/DEM/final_dem.dem|" master.res     
		sed -i "s|MASTER RESULTFILE:.*|MASTER RESULTFILE:\t${PROCESS}/INSAR_${master_date}/master.res|" master.res
		
		# 	create slave folder and go into
		mkdir ${sensing_date}
		cd ${sensing_date}
		
		# 	link to SLC folder
		ln -s ${SLC}/${sensing_date} SLC

		# 	get the master and slave doris result files
		cp -f SLC/slave.res  .
		cp -f ../master.res .

		# 	adjust paths for current node		
		sed -i "s|Data_output_file:.*|Data_output_file:  $SLC/${sensing_date}/$sensing_date.slc|" slave.res
		sed -i "s|SLAVE RESULTFILE:.*|SLAVE RESULTFILE:\t$SLC/${sensing_date}/slave.res|" slave.res            	

		#ciop-log "INFO" "step_orbit for ${sensing_date} "
		#doris orbit_Envisat.dorisin
		#[ $? -ne 0 ] && return ${ERR_STEP_ORBIT}
	
		# 	copy Stamps version of coarse.dorisin into slave folder
		cp $DORIS_SCR/coarse.dorisin .
		rm -f coreg.out
	
		#	change number of corr. windows to 200 for safer processsing (especially for scenes with water)
		sed -i 's/CC_NWIN.*/CC_NWIN         200/' coarse.dorisin  
		
		ciop-log "INFO" "doing image coarse correlation for ${sensing_date}"
		doris coarse.dorisin > step_coarse.log
		[ $? -ne 0 ] && return ${ERR_STEP_COARSE}

		#	get all calculated coarse offsets (line 85 - 284) and take out the value which appears most for better calcultion of overall offset
		offsetL=`more coreg.out | sed -n -e 85,284p | awk $'{print $5}' | sort | uniq -c | sort -g -r | head -1 | awk $'{print $2}'`
		offsetP=`more coreg.out | sed -n -e 85,284p | awk $'{print $6}' | sort | uniq -c | sort -g -r | head -1 | awk $'{print $2}'`

		# 	write the lines with the new overall offset into variable	 
		replaceL=`echo -e "Coarse_correlation_translation_lines: \t" $offsetL`
		replaceP=`echo -e "Coarse_correlation_translation_pixels: \t" $offsetP`	

		# 	replace full line of overall offset
		sed -i "s/Coarse_correlation_translation_lines:.*/$replaceL/" coreg.out
		sed -i "s/Coarse_correlation_translation_pixels:.*/$replaceP/" coreg.out

		######################################
		######check for CPM size##############
		######################################
	
		ciop-log "INFO" "doing image fine correlation for ${sensing_date}"
		step_coreg_simple
		[ $? -ne 0 ] && return ${ERR_STEP_COREG}

		# prepare dem.dorisin with right dem path
		if [ ! -e ${PROCESS}/INSAR_${master_date}/dem.dorisin ]; then
			    sed -n '1,/step comprefdem/p' $DORIS_SCR/dem.dorisin > ${PROCESS}/INSAR_${master_date}/dem.dorisin
			    echo "# CRD_METHOD      trilinear" >> ${PROCESS}/INSAR_${master_date}/dem.dorisin
			    echo "CRD_INCLUDE_FE  OFF" >> ${PROCESS}/INSAR_${master_date}/dem.dorisin
			    echo "CRD_OUT_FILE    refdem_1l.raw" >> ${PROCESS}/INSAR_${master_date}/dem.dorisin
			    echo "CRD_OUT_DEM_LP  dem_radar.raw" >> ${PROCESS}/INSAR_${master_date}/dem.dorisin
			    grep "SAM_IN" ${PROCESS}/INSAR_${master_date}/timing.dorisin | sed 's/SAM/CRD/' >> ${PROCESS}/INSAR_${master_date}/dem.dorisin	    
			    echo "STOP" >> ${PROCESS}/INSAR_${master_date}/dem.dorisin

			    sed -i "s|CRD_IN_DEM.*|CRD_IN_DEM ${TMPDIR}/DEM/final_dem.dem|" ${PROCESS}/INSAR_${master_date}/dem.dorisin
			    sed -i "s|SAM_IN_DEM.*|SAM_IN_DEM ${TMPDIR}/DEM/final_dem.dem|" ${PROCESS}/INSAR_${master_date}/timing.dorisin
		fi

		ciop-log "INFO" "doing image simamp for ${sensing_date}"
		step_dem
		[ $? -ne 0 ] && return ${ERR_STEP_DEM}

		ciop-log "INFO" "doing resample for ${sensing_date}"
		step_resample
		[ $? -ne 0 ] && return ${ERR_STEP_RESAMPLE}

		ciop-log "INFO" "doing ifg generation for ${sensing_date}"
		step_ifg
		[ $? -ne 0 ] && return ${ERR_STEP_IFG}

		cd ${PROCESS}/INSAR_${master_date}
        	ciop-log "INFO" "create tar"
        	tar cvfz INSAR_${sensing_date}.tgz ${sensing_date}
        	[ $? -ne 0 ] && return ${ERR_INSAR_TAR}

		#ciop-log "INFO" "Publish -a insar_slaves"
		insar_slaves="$( ciop-publish -a ${PROCESS}/INSAR_${master_date}/INSAR_${sensing_date}.tgz )"
		
		ciop-log "INFO" "Will publish the final output"
		echo "${insar_master},${insar_slaves},${dem}" | ciop-publish -s	
		[ $? -ne 0 ] && return ${ERR_FINAL_PUBLISH}

	fi 

done

}
cat | main
exit ${SUCCESS}
