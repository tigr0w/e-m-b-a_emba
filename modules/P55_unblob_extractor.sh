#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2023 Siemens Energy AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
#
# Author(s): Michael Messner

# Description:  Extracts firmware with unblob to the module log directory.
#               IMPORTANT: The results are currently not used for further analysis.
#               This module is currently only for evaluation purposes.

# Pre-checker threading mode - if set to 1, these modules will run in threaded mode
# This module extracts the firmware and is blocking modules that needs executed before the following modules can run
export PRE_THREAD_ENA=0

P55_unblob_extractor() {
  module_log_init "${FUNCNAME[0]}"

  # shellcheck disable=SC2153
  if [[ -d "${FIRMWARE_PATH}" ]] && [[ "${RTOS}" -eq 1 ]]; then
    detect_root_dir_helper "${FIRMWARE_PATH}"
  fi

  # If we have not found a linux filesystem we try to do an unblob extraction round
  if [[ ${RTOS} -eq 0 ]] ; then
    module_end_log "${FUNCNAME[0]}" 0
    return
  fi

  if [[ -f "${TMP_DIR}""/unblob_disable.cfg" ]]; then
    # if we disable unblob from a background module we need to work with a file to
    # store the state of this variable (bash rules ;))
    UNBLOB="$(cat "${TMP_DIR}"/unblob_disable.cfg)"
  fi

  if [[ "${UNBLOB}" -eq 0 ]]; then
    if [[ -f "${TMP_DIR}""/unblob_disable.cfg" ]]; then
      print_output "[-] Unblob module automatically disabled from other module."
    else
      print_output "[-] Unblob module currently disabled - enable it in emba setting the UNBLOB variable to 1"
    fi
    module_end_log "${FUNCNAME[0]}" 0
    return
  fi

  local FW_PATH_UNBLOB="${FIRMWARE_PATH}"

  if [[ -d "${FW_PATH_UNBLOB}" ]]; then
    print_output "[-] Unblob module only deals with firmware files - directories are handled via deep extractor"
    module_end_log "${FUNCNAME[0]}" 0
    return
  fi

  if ! command -v unblob >/dev/null; then
    print_output "[-] Unblob not correct installed - check your installation"
    return
  fi

  local FILES_EXT_UB=0
  local UNIQUE_FILES_UB=0
  local DIRS_EXT_UB=0
  local BINS_UB=0

  module_title "Unblob binary firmware extractor"
  pre_module_reporter "${FUNCNAME[0]}"

  export LINUX_PATH_COUNTER_UNBLOB=0
  export OUTPUT_DIR_UNBLOB="${LOG_DIR}"/firmware/unblob_extracted

  if [[ -f "${FW_PATH_UNBLOB}" ]]; then
    unblobber "${FW_PATH_UNBLOB}" "${OUTPUT_DIR_UNBLOB}"
  fi

  linux_basic_identification_unblobber "${OUTPUT_DIR_UNBLOB}"

  print_ln

  if [[ -d "${OUTPUT_DIR_UNBLOB}" ]]; then
    FILES_EXT_UB=$(find "${OUTPUT_DIR_UNBLOB}" -xdev -type f | wc -l )
    UNIQUE_FILES_UB=$(find "${OUTPUT_DIR_UNBLOB}" "${EXCL_FIND[@]}" -xdev -type f -exec md5sum {} \; 2>/dev/null | sort -u -k1,1 | cut -d\  -f3 | wc -l )
    DIRS_EXT_UB=$(find "${OUTPUT_DIR_UNBLOB}" -xdev -type d | wc -l )
    BINS_UB=$(find "${OUTPUT_DIR_UNBLOB}" "${EXCL_FIND[@]}" -xdev -type f -exec file {} \; | grep -c "ELF" || true)
  fi

  if [[ "${BINS_UB}" -gt 0 ]] || [[ "${FILES_EXT_UB}" -gt 0 ]]; then
    sub_module_title "Firmware extraction details"
    print_output "[*] ${ORANGE}Unblob${NC} results:"
    print_output "[*] Found ${ORANGE}${FILES_EXT_UB}${NC} files (${ORANGE}${UNIQUE_FILES_UB}${NC} unique files) and ${ORANGE}${DIRS_EXT_UB}${NC} directories at all."
    print_output "[*] Found ${ORANGE}${BINS_UB}${NC} binaries."
    print_output "[*] Additionally the Linux path counter is ${ORANGE}${LINUX_PATH_COUNTER_UNBLOB}${NC}."
    print_ln
    tree -sh "${OUTPUT_DIR_UNBLOB}" | tee -a "${LOG_FILE}"
    print_ln

    detect_root_dir_helper "${OUTPUT_DIR_UNBLOB}"

    write_csv_log "FILES Unblob" "UNIQUE FILES Unblob" "directories Unblob" "Binaries Unblob" "LINUX_PATH_COUNTER Unblob"
    write_csv_log "${FILES_EXT_UB}" "${UNIQUE_FILES_UB}" "${DIRS_EXT_UB}" "${BINS_UB}" "${LINUX_PATH_COUNTER_UNBLOB}"
  fi

  module_end_log "${FUNCNAME[0]}" "${FILES_EXT_UB}"
}

unblobber() {
  local FIRMWARE_PATH_="${1:-}"
  local OUTPUT_DIR_UNBLOB="${2:-}"
  local VERBOSE="${3:-1}"
  local UNBLOB_BIN="unblob"

  # unblob should be checked in the dependency checker

  if [[ "${DIFF_MODE}" -ne 1 ]]; then
    sub_module_title "Analyze binary firmware blob with unblob"
  fi

  print_output "[*] Extracting firmware to directory ${ORANGE}${OUTPUT_DIR_UNBLOB}${NC}"

  if ! [[ -d "${OUTPUT_DIR_UNBLOB}" ]]; then
    mkdir -p "${OUTPUT_DIR_UNBLOB}"
  fi

  if [[ "${VERBOSE}" -eq 1 ]]; then
    timeout --preserve-status --signal SIGINT 300 "${UNBLOB_BIN}" -v -k --log "${LOG_PATH_MODULE}"/unblob_"$(basename "${FIRMWARE_PATH_}")".log -e "${OUTPUT_DIR_UNBLOB}" "${FIRMWARE_PATH_}" | tee -a "${LOG_FILE}" || true
  else
    COLUMNS=100 timeout --preserve-status --signal SIGINT 300 "${UNBLOB_BIN}" -k --log "${LOG_PATH_MODULE}"/unblob_"$(basename "${FIRMWARE_PATH_}")".log -e "${OUTPUT_DIR_UNBLOB}" "${FIRMWARE_PATH_}" | tee -a "${LOG_FILE}" || true
  fi

  print_ln
}

linux_basic_identification_unblobber() {
  local FIRMWARE_PATH_CHECK="${1:-}"
  if ! [[ -d "${FIRMWARE_PATH_CHECK}" ]]; then
    return
  fi
  LINUX_PATH_COUNTER_UNBLOB="$(find "${FIRMWARE_PATH_CHECK}" "${EXCL_FIND[@]}" -xdev -type d -iname bin -o -type f -iname busybox -o -type f -name shadow -o -type f -name passwd -o -type d -iname sbin -o -type d -iname etc 2> /dev/null | wc -l)"
}
