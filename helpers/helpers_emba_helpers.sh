#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2023 Siemens Energy AG
# Copyright 2020-2023 Siemens AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
#
# Author(s): Michael Messner, Pascal Eckmann

# Description: Multiple useful helpers

run_web_reporter_mod_name() {
  MOD_NAME="${1:-}"
  if [[ ${HTML} -eq 1 ]]; then
    # usually we should only find one file:
    mapfile -t LOG_FILES < <(find "${LOG_DIR}" -maxdepth 1 -type f -iname "${MOD_NAME}*.txt" | sort)
    for LOG_FILE in "${LOG_FILES[@]}"; do
      MOD_NAME=$(basename -s .txt "${LOG_FILE}")
      generate_report_file "${LOG_FILE}"
      sed -i -E '/^\[REF\]|\[ANC\].*/d' "${LOG_FILE}"
    done
  fi
}

wait_for_pid() {
  local WAIT_PIDS=("$@")
  local PID
  # print_output "[*] wait pid protection: ${#WAIT_PIDS[@]}"
  for PID in "${WAIT_PIDS[@]}"; do
    # print_output "[*] wait pid protection: $PID"
    print_dot
    if ! [[ -e /proc/"${PID}" ]]; then
      continue
    fi
    while [[ -e /proc/"${PID}" ]]; do
      # print_output "[*] wait pid protection - running pid: $PID"
      print_dot
      # if S115 is running we have to kill old qemu processes
      if [[ -f "${LOG_DIR}"/"${MAIN_LOG_FILE}" ]] && [[ $(grep -i -c S115_ "${LOG_DIR}"/"${MAIN_LOG_FILE}") -gt 0 && -n "${QRUNTIME}" ]]; then
        killall -9 --quiet --older-than "${QRUNTIME}" -r .*qemu-.*-sta.* || true
      fi
    done
  done
}

max_pids_protection() {
  if [[ -n "${1:-}" ]]; then
    local MAX_PIDS_="${1:-}"
    shift
  else
    local MAX_PIDS_="${MAX_MODS:1}"
  fi
  local WAIT_PIDS=("$@")
  local PID
  while [[ ${#WAIT_PIDS[@]} -gt "${MAX_PIDS_}" ]]; do
    local TEMP_PIDS=()
    # check for really running PIDs and re-create the array
    for PID in "${WAIT_PIDS[@]}"; do
      # print_output "[*] max pid protection: ${#WAIT_PIDS[@]}"
      if [[ -e /proc/"${PID}" ]]; then
        if ! grep -q "State:.*zombie.*" "/proc/${PID}/status" 2>/dev/null; then
          TEMP_PIDS+=( "${PID}" )
        fi
      fi
    done
    # if S115 is running we have to kill old qemu processes
    if [[ -f "${LOG_DIR}"/"${MAIN_LOG_FILE}" ]] && [[ $(grep -i -c S115_ "${LOG_DIR}"/"${MAIN_LOG_FILE}" || true) -eq 1 && -n "${QRUNTIME}" ]]; then
      killall -9 --quiet --older-than "${QRUNTIME}" -r .*qemu.*sta.* || true
    fi

    # print_output "[!] really running pids: ${#TEMP_PIDS[@]}"

    # recreate the arry with the current running PIDS
    WAIT_PIDS=()
    WAIT_PIDS=("${TEMP_PIDS[@]}")
    print_dot
  done
}

# $1 - 1 some interrupt detected
# $1 - 0 default exit 0
cleaner() {
  INTERRUPT_CLEAN="${1:-1}"
  [[ "${CLEANED}" -eq 1 ]] && return
  if [[ "${INTERRUPT_CLEAN}" -eq 1 ]]; then
    print_output "[*] Interrupt detected!" "no_log"
  fi
  print_output "[*] Final cleanup started." "no_log"
  if [[ "${IN_DOCKER}" -eq 0 ]] && [[ -n "${QUEST_CONTAINER}" ]]; then
    if [[ "$( docker container inspect -f '{{.State.Status}}' "${QUEST_CONTAINER}" )" == "running" ]]; then
      print_output "[*] Stopping Quest Container ..." "no_log"
      docker kill "${QUEST_CONTAINER}"
    fi
  fi
  # stop inotifywait on host
  if [[ "${IN_DOCKER}" -eq 0 ]] && pgrep -f "inotifywait.*${LOG_DIR}.*" &> /dev/null 2>&1; then
    print_output "[*] Stopping inotify ..."
    pkill -f "inotifywait.*${LOG_DIR}.*" || true
  fi

  # Remove status bar and reset screen
  [[ "${DISABLE_STATUS_BAR}" -eq 0 ]] && remove_status_bar

  # if S115 is found only once in main.log the module was started and we have to clean it up
  # additionally we need to check some variable from a running EMBA instance
  # otherwise the unmounter runs crazy in some corner cases
  if [[ -f "${LOG_DIR}"/"${MAIN_LOG_FILE}" && "${#FILE_ARR[@]}" -gt 0 ]]; then
    if [[ $(grep -i -c S115 "${LOG_DIR}"/"${MAIN_LOG_FILE}") -eq 1 ]]; then

      print_output "[*] Terminating qemu processes - check it with ps" "no_log"
      killall -9 --quiet -r .*qemu-.*-sta.* > /dev/null || true
      print_output "[*] Cleaning the emulation environment\\n" "no_log"
      find "${FIRMWARE_PATH_CP}" -xdev -iname "qemu*static" -exec rm {} \; 2>/dev/null || true
      find "${LOG_DIR}/s115_usermode_emulator" -xdev -iname "qemu*static" -exec rm {} \; 2>/dev/null || true

      print_output "[*] Umounting proc, sys and run" "no_log"
      mapfile -t CHECK_MOUNTS < <(mount | grep "s115_usermode_emulator" 2>/dev/null || true)
      # now we can unmount the stuff from emulator and delete temporary stuff
      for MOUNT in "${CHECK_MOUNTS[@]}"; do
        print_output "[*] Unmounting ${MOUNT}" "no_log"
        MOUNT=$(echo "${MOUNT}" | cut -d\  -f3)
        umount -l "${MOUNT}" || true
      done

      if [[ -d "${LOG_DIR}/s115_usermode_emulator/firmware" ]]; then
        print_output "[*] Removing emulation directory ${ORANGE}${LOG_DIR}/s115_usermode_emulator/firmware${NC}" "no_log"
        rm -r "${LOG_DIR}/s115_usermode_emulator/firmware" || true
      fi
    fi

    if [[ $(grep -i -c S120 "${LOG_DIR}"/"${MAIN_LOG_FILE}") -eq 1 ]]; then
      print_output "[*] Terminating cwe-checker processes - check it with ps" "no_log"
      killall -9 --quiet -r .*cwe_checker.* > /dev/null || true
    fi

    # If SYS_ONLINE is 1 and some qemu system process is running, the live system tester (system mode emulator)
    # was able to setup the box we need to do a cleanup
    if pgrep -f "qemu-system-.*${LOG_DIR}"; then
      if [[ "${SYS_ONLINE:-0}" -eq 1 ]] || [[ $(grep -i -c L10 "${LOG_DIR}"/"${MAIN_LOG_FILE}") -gt 0 ]]; then
        print_output "[*] Resetting system emulation environment" "no_log"
        stopping_emulation_process
        reset_network_emulation 2
      fi
    fi
  fi
  [[ "${IN_DOCKER}" -eq 1 ]] && restore_permissions

  if [[ "${IN_DOCKER}" -eq 0 ]] && [[ -v K_DOWN_PID ]]; then
    if ps -p "${K_DOWN_PID}" > /dev/null; then
      # kernel downloader is running in a thread on the host and needs to be stopped now
      print_output "[*] Stopping kernel downloader thread with PID ${K_DOWN_PID}" "no_log"
      kill "${K_DOWN_PID}" > /dev/null || true
    fi
  fi

  if [[ -f "${TMP_DIR}"/orig_logdir ]]; then
    LOG_DIR_HOST=$(cat "${TMP_DIR}"/orig_logdir)
    pkill -f "inotifywait.*${LOG_DIR_HOST}" 2>/dev/null || true
  fi

  if [[ "${IN_DOCKER}" -eq 1 ]]; then
    fuser -k "${LOG_DIR}" || true
    fuser -k "${FIRMWARE_PATH}" || true
  fi

  if [[ "${IN_DOCKER}" -eq 0 ]] && [[ -f "${TMP_DIR}"/EXIT_KILL_PIDS.log ]]; then
    while read -r KILL_PID; do
      if [[ -e /proc/"${KILL_PID}" ]]; then
        print_output "[*] Stopping EMBA process with PID ${KILL_PID}" "no_log"
        kill -9 "${KILL_PID}" > /dev/null || true
      fi
    done < "${TMP_DIR}"/EXIT_KILL_PIDS.log
  fi

  if [[ "${IN_DOCKER}" -eq 0 ]] && [[ -d "${TMP_DIR}" ]]; then
    rm -r "${TMP_DIR}" 2>/dev/null || true
  fi
  export CLEANED=1
  if [[ "${INTERRUPT_CLEAN}" -eq 1 ]]; then
    print_output "[!] Test ended on ""$(date)"" and took about ""$(show_runtime)"" \\n" "no_log"
    exit 1
  fi
}

emba_updater() {
  print_output "[*] EMBA update starting ..." "no_log"

  if [[ -d ./.git ]]; then
    git pull origin master
  else
    print_output "[-] INFO: Can't update non git version of EMBA"
  fi

  EMBA="${INVOCATION_PATH}" FIRMWARE="${FIRMWARE_PATH}" LOG="${LOG_DIR}" docker pull embeddedanalyzer/emba

  if command -v cve_searchsploit > /dev/null ; then
    print_output "[*] EMBA update - cve_searchsploit update" "no_log"
    cve_searchsploit -u
  fi

  print_output "[*] EMBA update - cve-search update" "no_log"
  /etc/init.d/redis-server start
  "${EXT_DIR}"/cve-search/sbin/db_updater.py -v

  print_output "[*] Please note that this was only a data update and no installed packages were updated." "no_log"
  print_output "[*] Please restart your EMBA scan to apply the updates ..." "no_log"
}

# this checks if a function is available
# this means the EMBA module was loaded
function_exists() {
  FCT_TO_CHECK="${1:-}"
  declare -f -F "${FCT_TO_CHECK}" > /dev/null
  return $?
}

# used by CSV search to get the search rule for csv search:
get_csv_rule() {
  local VERSION_STRING="${1:-}"
  local CSV_REGEX
  CSV_REGEX=$(echo "${2:-}" | sed 's/^\"//' | sed 's/\"$//')
  export CSV_RULE
  CSV_RULE="NA"

  CSV_RULE="$(echo "${VERSION_STRING}" | eval "${CSV_REGEX}" || true)"
}

enable_strict_mode() {
  local STRICT_MODE_="${1:-0}"
  local PRINTER="${2:-1}"

  if [[ "${STRICT_MODE_}" -eq 1 ]]; then
    # http://redsymbol.net/articles/unofficial-bash-strict-mode/
    # https://github.com/tests-always-included/wick/blob/master/doc/bash-strict-mode.md
    # shellcheck source=./installer/wickStrictModeFail.sh
    # shellcheck disable=SC1091
    source ./installer/wickStrictModeFail.sh
    load_strict_mode_settings
    trap 'wickStrictModeFail $? | tee -a "${LOG_DIR}"/emba_error.log' ERR  # The ERR trap is triggered when a script catches an error

    if [[ "${PRINTER}" -eq 1 ]]; then
      print_bar "no_log"
      print_output "[!] INFO: EMBA running in STRICT mode!" "no_log"
      print_bar "no_log"
    fi
  fi
}

disable_strict_mode() {
  local STRICT_MODE_="${1:-0}"
  local PRINTER="${2:-1}"

  if [[ "${STRICT_MODE_}" -eq 1 ]]; then
    # disable all STRICT_MODE settings - can be used for modules that are not compatible
    # WARNING: this should only be a temporary solution. The goal is to make modules
    # STRICT_MODE compatible

    unset -f wickStrictModeFail
    set +e          # Exit immediately if a command exits with a non-zero status
    set +u          # Exit and trigger the ERR trap when accessing an unset variable
    set +o pipefail # The return value of a pipeline is the value of the last (rightmost) command to exit with a non-zero status
    set +E          # The ERR trap is inherited by shell functions, command substitutions and commands in subshells
    shopt -u extdebug # Enable extended debugging
    unset IFS
    trap - ERR
    set +x

    if [[ "${PRINTER}" -eq 1 ]]; then
      print_bar "no_log"
      print_output "[!] INFO: EMBA STRICT mode disabled!" "no_log"
      print_bar "no_log"
    fi
  fi
}

restore_permissions() {
  if [[ -f "${LOG_DIR}"/orig_user.log ]]; then
    ORIG_USER=$(head -1 "${LOG_DIR}"/orig_user.log)
    print_output "[*] Restoring directory permissions for user: ${ORANGE}${ORIG_USER}${NC}" "no_log"
    ORIG_UID="$(grep "UID" "${LOG_DIR}"/orig_user.log | awk '{print $2}')"
    ORIG_GID="$(grep "GID" "${LOG_DIR}"/orig_user.log | awk '{print $2}')"
    chown "${ORIG_UID}":"${ORIG_GID}" "${LOG_DIR}" -R || true
    rm "${LOG_DIR}"/orig_user.log || true
  fi
}

backup_var() {
  local VAR_NAME="${1:-}"
  local VAR_VALUE="${2:-}"
  local BACKUP_FILE="${LOG_DIR}""/backup_vars.log"

  echo "export ${VAR_NAME}=\"${VAR_VALUE}\"" >> "${BACKUP_FILE}"
}

module_wait() {
  local MODULE_TO_WAIT="${1:-}"
  # if the module we should wait is not in our module array we return without waiting
  if ! [[ " ${MODULES_EXPORTED[*]} " == *"${MODULE_TO_WAIT}"* ]]; then
    print_output "[-] $(date) - ${MODULE_TO_WAIT} not in module array - this will result in unexpected behavior" "main"
    return
  fi

  while ! [[ -f "${MAIN_LOG}" ]]; do
    sleep 1
  done

  while [[ $(grep -i -c "${MODULE_TO_WAIT} finished" "${MAIN_LOG}" || true) -ne 1 ]]; do
    if grep -q "${MODULE_TO_WAIT} not executed - blacklist triggered" "${MAIN_LOG}"; then
      print_output "[-] $(date) - ${MODULE_TO_WAIT} blacklisted - not waiting" "main"
      # if our module which we are waiting is on the blacklist we can just return
      return
    fi
    sleep 1
  done
}

store_kill_pids() {
  local PID="${1:-}"
  ! [[ -d "${TMP_DIR}" ]] && mkdir -p "${TMP_DIR}"
  [[ "${IN_DOCKER}" -eq 0 ]] && echo "${PID}" >> "${TMP_DIR}"/EXIT_KILL_PIDS.log
  [[ "${IN_DOCKER}" -eq 1 ]] && echo "${PID}" >> "${TMP_DIR}"/EXIT_KILL_PIDS_DOCKER.log
  return 0
}

disk_space_monitor() {
  local DDISK="${LOG_DIR}"

  while ! [[ -f "${MAIN_LOG}" ]]; do
    sleep 1
  done

  while true; do
    # print_output "[*] Disk space monitoring active" "no_log"
    FREE_SPACE=$(df --output=avail "${DDISK}" | awk 'NR==2')
    if [[ "${FREE_SPACE}" -lt 10000000 ]]; then
      print_ln "no_log"
      print_output "[!] WARNING: EMBA is running out of disk space!" "main"
      print_output "[!] WARNING: EMBA is stopping now" "main"
      df -h || true
      print_ln "no_log"
      # give the container some more seconds for the cleanup process
      [[ "${IN_DOCKER}" -eq 0 ]] && sleep 5
      cleaner 1
    fi

    if [[ -f "${MAIN_LOG}" ]]; then
      if grep -q "Test ended\|EMBA failed" "${MAIN_LOG}" 2>/dev/null; then
        break
      fi
    fi

    sleep 5
  done
}
