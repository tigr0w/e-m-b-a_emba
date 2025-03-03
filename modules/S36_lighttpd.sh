#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2025 Siemens Energy AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
# SPDX-License-Identifier: GPL-3.0-only
#
# Author(s): Michael Messner
#
# Description:  This module tests identified lighttpd configuration files for interesting areas.
#               It is based on details from the following sources:
#               https://wiki.alpinelinux.org/wiki/Lighttpd_Advanced_security
#               https://security-24-7.com/hardening-guide-for-lighttpd-1-4-26-on-redhat-5-5-64bit-edition/
#               https://redmine.lighttpd.net/projects/lighttpd/wiki/Docs_SSL
#               https://redmine.lighttpd.net/projects/lighttpd/repository/14/revisions/master/entry/doc/config/lighttpd.conf
#               The module results should be reviewed in details. There are probably a lot of cases
#               which we are currently not handling correct.


S36_lighttpd() {
  module_log_init "${FUNCNAME[0]}"
  module_title "Lighttpd web server analysis"
  pre_module_reporter "${FUNCNAME[0]}"

  local lNEG_LOG=0
  local lLIGHTTP_CFG_ARR=()
  local lLIGHTTP_BIN_ARR=()
  local lCFG_FILE=""

  readarray -t lLIGHTTP_CFG_ARR < <( find "${FIRMWARE_PATH}" -xdev "${EXCL_FIND[@]}" -iname '*lighttp*conf*' -print0|xargs -r -0 -P 16 -I % sh -c 'md5sum "%" 2>/dev/null' | sort -u -k1,1 | cut -d\  -f3 || true)
  readarray -t lLIGHTTP_BIN_ARR < <( find "${FIRMWARE_PATH}" -xdev "${EXCL_FIND[@]}" -type f -iname 'lighttpd' -print0|xargs -r -0 -P 16 -I % sh -c 'file "%" 2>/dev/null | grep "ELF" | cut -d ':' -f1' | sort -u || true)

  if [[ ${#lLIGHTTP_BIN_ARR[@]} -gt 0 ]] ; then
    lighttpd_binary_analysis "${lLIGHTTP_BIN_ARR[@]}"
    # -> sets LIGHT_VERSIONS array
  fi

  if [[ ${#lLIGHTTP_CFG_ARR[@]} -gt 0 ]] ; then
    for lCFG_FILE in "${lLIGHTTP_CFG_ARR[@]}" ; do
      lighttpd_config_analysis "${lCFG_FILE}" "${LIGHT_VERSIONS[@]}"
      write_csv_log "Lighttpd web server configuration file" "$(basename "${lCFG_FILE}")" "${lCFG_FILE}"
      local lNEG_LOG=1
    done
  else
    print_output "[-] No Lighttpd related configuration files found"
  fi

  module_end_log "${FUNCNAME[0]}" "${lNEG_LOG}"
}

lighttpd_binary_analysis() {
  sub_module_title "Lighttpd binary analysis"
  local lLIGHTTP_BIN_ARR=("${@}")
  export LIGHT_VERSIONS=()
  local lLIGHT_VER=""
  local lVERSION_LINE=""
  local lCSV_REGEX=""
  local lLIC=""
  local lVERSION_FINDER=""
  local lVERSION_IDENTIFIER=""
  local lVULNERABLE_FUNCTIONS_VAR=""
  local lVULNERABLE_FUNCTIONS_ARR=()
  local lLIGHT_BIN=""
  local lCSV_RULE=""

  local lOS_IDENTIFIED=""
  local lBIN_ARCH=""
  local lAPP_NAME=""
  local lAPP_MAINT=""
  local lAPP_VERS=""
  local lPURL_IDENTIFIER=""
  local lCPE_IDENTIFIER=""
  local lPACKAGING_SYSTEM="static_lighttpd_analysis"

  lOS_IDENTIFIED=$(distri_check)

  if [[ -f "${S09_CSV_LOG}" ]] && grep -q "lighttpd" "${S09_CSV_LOG}"; then
    # if we already have results from s09 we just use them
    mapfile -t LIGHT_VERSIONS < <(grep "lighttpd" "${S09_CSV_LOG}" | cut -d\; -f4 | sort -u || true)
  else
    # most of the time we run through the lighttpd version identifiers and check them against the lighttpd binaries
    while read -r lVERSION_LINE; do
      if safe_echo "${lVERSION_LINE}" | grep -v -q "^[^#*/;]"; then
        continue
      fi
      if safe_echo "${lVERSION_LINE}" | grep -q ";no_static;"; then
        continue
      fi
      if safe_echo "${lVERSION_LINE}" | grep -q ";live;"; then
        continue
      fi

      lCSV_REGEX="$(echo "${lVERSION_LINE}" | cut -d\; -f5)"
      lLIC="$(safe_echo "${lVERSION_LINE}" | cut -d\; -f3)"
      lVERSION_IDENTIFIER="$(safe_echo "${lVERSION_LINE}" | cut -d\; -f4)"
      lVERSION_IDENTIFIER="${lVERSION_IDENTIFIER/\"}"
      lVERSION_IDENTIFIER="${lVERSION_IDENTIFIER%\"}"

      for lLIGHT_BIN in "${lLIGHTTP_BIN_ARR[@]}" ; do
        lVERSION_FINDER=$(strings "${lLIGHT_BIN}" | grep -o -a -E "${lVERSION_IDENTIFIER}" | head -1 2> /dev/null || true)
        if [[ -n ${lVERSION_FINDER} ]]; then
          print_ln "no_log"
          print_output "[+] Version information found ${RED}${lVERSION_FINDER}${NC}${GREEN} in binary ${ORANGE}$(print_path "${lLIGHT_BIN}")${GREEN} (license: ${ORANGE}${lLIC}${GREEN}) (${ORANGE}static${GREEN})."
          lCSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${lCSV_REGEX}")
          LIGHT_VERSIONS+=( "${lCSV_RULE}" )

          lMD5_CHECKSUM="$(md5sum "${lLIGHT_BIN}" | awk '{print $1}')"
          lSHA256_CHECKSUM="$(sha256sum "${lLIGHT_BIN}" | awk '{print $1}')"
          lSHA512_CHECKSUM="$(sha512sum "${lLIGHT_BIN}" | awk '{print $1}')"

          lBIN_ARCH=$(file -b "${lLIGHT_BIN}" | cut -d ',' -f2)
          lBIN_ARCH=${lBIN_ARCH#\ }
          lCPE_IDENTIFIER=$(build_cpe_identifier "${lCSV_RULE}")
          lPURL_IDENTIFIER=$(build_generic_purl "${lCSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")
          lAPP_MAINT=$(echo "${lCSV_RULE}" | cut -d ':' -f2)
          lAPP_NAME=$(echo "${lCSV_RULE}" | cut -d ':' -f3)
          lAPP_VERS=$(echo "${lCSV_RULE}" | cut -d ':' -f4-5)

          # add source file path information to our properties array:
          local lPROP_ARRAY_INIT_ARR=()
          lPROP_ARRAY_INIT_ARR+=( "source_path:${lLIGHT_BIN}" )
          lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
          lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
          lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${lCSV_RULE}" )

          build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

          # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
          # final array with all hash values
          if ! build_sbom_json_hashes_arr "${lLIGHT_BIN}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}"; then
            print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
            continue
          fi

          # create component entry - this allows adding entries very flexible:
          build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${lLIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

          check_for_s08_csv_log "${S08_CSV_LOG}"
          write_log "${lPACKAGING_SYSTEM};${lLIGHT_BIN:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME,,};${lVERSION_IDENTIFIER:-NA};${lCSV_RULE:-NA};${lLIC:-NA};${lAPP_MAINT:-NA};${lBIN_ARCH:-NA};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
          continue
        fi
      done
    done < <(grep "^lighttpd" "${CONFIG_DIR}"/bin_version_strings.cfg)
  fi
  eval "LIGHT_VERSIONS=($(for i in "${LIGHT_VERSIONS[@]}" ; do echo "\"${i}\"" ; done | sort -u))"

  if [[ ${#LIGHT_VERSIONS[@]} -gt 0 ]] ; then
    print_ln
    # lets do a quick vulnerability check on our lighttpd version
    for lLIGHT_VER in "${LIGHT_VERSIONS[@]}"; do
      for lLIGH_JSON in "${SBOM_LOG_PATH}"/*lighttpd*.json; do
        lVERS=$(jq -r '.version' "${lLIGH_JSON}" || true)
        if [[ "${lVERS}" != "${lLIGHT_VER/*:}" ]]; then
          continue
        fi
        local lBOM_REF=""
        lBOM_REF=$(jq -r '."bom-ref"' "${lLIGH_JSON}" || true)
        local lORIG_SOURCE="lighttpd_static"
        local lVENDOR="lighttpd"
        local lPROD="lighttpd"
        cve_bin_tool_threader "${lBOM_REF}" "${lVENDOR}" "${lPROD}" "${lVERS}" "${lORIG_SOURCE}"
      done
    done
  fi

  # check for binary protections on lighttpd binaries
  print_ln
  print_output "[*] Testing lighttpd binaries for binary protection mechanisms:\\n"
  for lLIGHT_BIN in "${lLIGHTTP_BIN_ARR[@]}" ; do
    print_output "$("${EXT_DIR}"/checksec --file="${lLIGHT_BIN}" || true)"
  done

  print_ln
  print_output "[*] Testing lighttpd binaries for deprecated function calls:\\n"
  lVULNERABLE_FUNCTIONS_VAR="$(config_list "${CONFIG_DIR}""/functions.cfg")"
  # nosemgrep
  local IFS=" "
  IFS=" " read -r -a lVULNERABLE_FUNCTIONS_ARR <<<"$( echo -e "${lVULNERABLE_FUNCTIONS_VAR}" | sed ':a;N;$!ba;s/\n/ /g' )"
  for lLIGHT_BIN in "${lLIGHTTP_BIN_ARR[@]}" ; do
    if ( file "${lLIGHT_BIN}" | grep -q "x86-64" ) ; then
      function_check_x86_64 "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "Intel 80386" ) ; then
      function_check_x86 "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "32-bit.*ARM" ) ; then
      function_check_ARM32 "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "64-bit.*ARM" ) ; then
      function_check_ARM64 "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "MIPS" ) ; then
      function_check_MIPS "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "PowerPC" ) ; then
      function_check_PPC32 "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "Altera Nios II" ) ; then
      function_check_NIOS2 "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    elif ( file "${lLIGHT_BIN}" | grep -q "QUALCOMM DSP6" ) ; then
      radare_function_check_hexagon "${lLIGHT_BIN}" "${lVULNERABLE_FUNCTIONS_ARR[@]}"
    fi
  done
}

lighttpd_config_analysis() {
  local lLIGHTTPD_CONFIG="${1:-}"
  shift
  local lLIGHT_VERSIONS_ARR=("${@}")
  local lLIGHT_VER=""
  local lSSL_ENABLED=0
  local lPEM_FILES_ARR=()
  local lPEM_FILE=""
  local lREAL_PEMS_ARR=()
  local lREAL_PEM=""

  if ! [[ -f "${lLIGHTTPD_CONFIG}" ]]; then
    print_output "[-] No configuration file available"
    return
  fi
  sub_module_title "Lighttpd configuration analysis for $(basename "${lLIGHTTPD_CONFIG}")"

  print_output "[*] Testing web server configuration file ${ORANGE}${lLIGHTTPD_CONFIG}${NC}\\n"
  print_output "[*] Testing web server user"
  if grep "user=root" "${lLIGHTTPD_CONFIG}" | grep -E -v -q "^([[:space:]])?#"; then
    print_output "[+] Possible configuration issue detected: ${ORANGE}Web server running as root user:${NC}"
    print_output "$(indent "$(orange "$(grep "user=root" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi
  if grep -E "server.username.*root" "${lLIGHTTPD_CONFIG}" | grep -E -v -q "^([[:space:]])?#"; then
    print_output "[+] Possible configuration issue detected: ${ORANGE}Web server running as root user:${NC}"
    print_output "$(indent "$(orange "$(grep -E "server.username.*root" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi
  if grep -E "server.groupname.*root" "${lLIGHTTPD_CONFIG}" | grep -E -v -q "^([[:space:]])?#"; then
    print_output "[+] Possible configuration issue detected: ${ORANGE}Web server running as root group:${NC}"
    print_output "$(indent "$(orange "$(grep -E "server.groupname.*root" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi

  print_output "[*] Testing web server root directory location"
  if grep -E "server_root\|server\.document-root" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
    print_output "[*] ${ORANGE}Configuration note:${NC} Web server using the following root directory"
    print_output "$(indent "$(orange "$(grep -E "server_root\|server\.document-root" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi
  if grep -E "server_root\|server\.document-root.*\"\/\"" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
    print_output "[*] ${ORANGE}Possible configuration issue detected:${NC} Web server exposes filesystem"
    print_output "$(indent "$(orange "$(grep -E "server_root\|server\.document-root" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi

  print_output "[*] Testing for additional web server binaries"
  if grep -E "bin-path" "${lLIGHTTPD_CONFIG}" | grep -E -v -q "^([[:space:]])?#"; then
    print_output "[*] ${ORANGE}Configuration note:${NC} Web server using the following additional binaries"
    print_output "$(indent "$(orange "$(grep -E "bin-path" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi

  print_output "[*] Testing for directory listing configuration"
  if grep -E "dir-listing.activate.*enable" "${lLIGHTTPD_CONFIG}" | grep -E -v -q "^([[:space:]])?#"; then
    print_output "[+] Configuration issue detected: ${ORANGE}Web server allows directory listings${NC}"
    print_output "$(indent "$(orange "$(grep -E "dir-listing.activate.*enable" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi
  if grep -E "server.dir-listing.*enable" "${lLIGHTTPD_CONFIG}" | grep -E -v -q "^([[:space:]])?#"; then
    print_output "[+] Configuration issue detected: ${ORANGE}Web server allows directory listings${NC}"
    print_output "$(indent "$(orange "$(grep -E "server.dir-listing.*enable" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#")")")"
  fi

  print_output "[*] Testing web server ssl.engine usage"
  if (! grep -E "ssl.engine.*enable" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#") && (! grep -E "server.modules.*mod_openssl" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"); then
    print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not using ssl engine${NC}"
  else
    lSSL_ENABLED=1
  fi

  if [[ "${lSSL_ENABLED}" -eq 1 ]]; then
    print_output "[*] Testing web server pemfile location"
    if grep -E "ssl.pemfile" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
      print_output "[*] ${ORANGE}Configuration note:${NC} Web server using the following pem file"
      print_output "$(indent "$(orange "$(grep -E "ssl.pemfile" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      mapfile -t lPEM_FILES_ARR < <(grep -E "ssl.pemfile" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" | cut -d= -f2 | tr -d '"' || true)
      for lPEM_FILE in "${lPEM_FILES_ARR[@]}"; do
        lPEM_FILE=$(echo "${lPEM_FILE}" | tr -d "[:space:]")
        mapfile -t lREAL_PEMS_ARR < <(find "${FIRMWARE_PATH}" -wholename "*${lPEM_FILE}" || true)
        for lREAL_PEM in "${lREAL_PEMS_ARR[@]}"; do
          print_output "[*] ${ORANGE}Configuration note:${NC} Web server pem file found: ${ORANGE}${lREAL_PEM}${NC}"
          print_output "[*] $(find "${lREAL_PEM}" -ls)"
          # Todo: check for permissions 400 on pem file
          if [[ "$(stat -c "%a" "${lREAL_PEM}")" -ne 400 ]]; then
            print_output "[+] Possible configuration issue detected: ${ORANGE}Privileges of web server pem file not correct${NC}"
          fi
        done
      done
    fi
    print_output "[*] Testing web server private key file"
    if grep -E "ssl.privkey" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
      print_output "[*] ${ORANGE}Configuration note:${NC} Web server using the following private key file"
      print_output "$(indent "$(orange "$(grep -E "ssl.privkey" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
    fi

    print_output "[*] Testing web server BEAST mitigation"
    if grep -E "ssl.disable-client-renegotiation.*disable" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
      if [[ ${#lLIGHT_VERSIONS_ARR[@]} -gt 0 ]] ; then
        for lLIGHT_VER in "${lLIGHT_VERSIONS_ARR[@]}"; do
          lLIGHT_VER="${lLIGHT_VER/*:/}"
          if [[ "$(version "${lLIGHT_VER}")" -lt "$(version "1.4.68")" ]]; then
            print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not mitigating the BEAST attack (CVE-2009-3555) via ssl.disable-client-renegotiation.${NC}"
            print_output "$(indent "$(orange "$(grep -E "ssl.disable-client-renegotiation.*disable" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#" || true)")")"
          fi
        done
      else
        # just in case we have not found a version number we show the warning.
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not mitigating the BEAST attack (CVE-2009-3555) via ssl.disable-client-renegotiation.${NC}"
        print_output "$(indent "$(orange "$(grep -E "ssl.disable-client-renegotiation.*disable" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#" || true)")")"
      fi
    fi

    print_output "[*] Testing web server for SSL ciphers supported"
    print_output "$(indent "$(orange "$(grep "ssl.cipher-list\|ssl.openssl.ssl-conf-cmd" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"

    if grep "ssl.cipher-list\|ssl.openssl.ssl-conf-cmd" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then

      print_output "[*] Testing web server POODLE attack mitigation"
      if grep -E "ssl.cipher-list.*:SSLv3" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        if [[ ${#lLIGHT_VERSIONS_ARR[@]} -eq 0 ]] ; then
          # if we have no version detected we show this issue:
          print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not mitigating the POODLE attack (CVE-2014-3566) via disabled SSLv3 ciphers.${NC}"
          print_output "[*] Note that SSLv3 is automatically disabled on lighttpd since version ${ORANGE}1.4.36${NC}"
          print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
        fi

        for lLIGHT_VER in "${lLIGHT_VERSIONS_ARR[@]}"; do
          lLIGHT_VER="${lLIGHT_VER/*:/}"
          if [[ "$(version "${lLIGHT_VER}")" -le "$(version "1.4.35")" ]]; then
            print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not mitigating the POODLE attack (CVE-2014-3566) via disabled SSLv3 ciphers.${NC}"
            print_output "[*] Note that SSLv3 is automatically disabled on lighttpd since version ${ORANGE}1.4.36${NC}"
            print_output "[*] EMBA detected lighttpd version ${ORANGE}${lLIGHT_VER}${NC}"
            print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
          fi
        done
      fi

      print_output "[*] Testing web server enabled minimal TLS version"
      if (! grep -E "ssl.openssl.*MinProtocol.*TLSv1.[23]" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"); then
        print_output "[+] Possible configuration issue detected: ${ORANGE}No web server minimal TLS version enforced.${NC}"
        print_output "$(indent "$(orange "$(grep -E "ssl.use-sslv2" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server enabled SSLv2"
      if grep -E "ssl.use-sslv2.*enable" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server enables SSLv2 ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep -E "ssl.use-sslv2" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server enabled SSLv3"
      if grep -E "ssl.use-sslv3.*enable" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server enables SSLv3 ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep -E "ssl.use-sslv3" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server FREAK attack mitigation"
      if grep -E "ssl.cipher-list.*:EXPORT" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not disabling EXPORT ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server NULL ciphers"
      if grep -E "ssl.cipher-list.*:[ae]NULL" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not disabling NULL ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server RC4 ciphers"
      if grep -E  "ssl.cipher-list.*:RC4" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not disabling RC4 ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server DES ciphers"
      if grep -E "ssl.cipher-list.*:DES" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not disabling DES ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -q -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server 3DES ciphers"
      if grep -E "ssl.cipher-list.*:3DES" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not disabling 3DES ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u | grep -q -E -v "^([[:space:]])?#" || true)")")"
      fi

      print_output "[*] Testing web server MD5 ciphers"
      if grep -E "ssl.cipher-list.*:MD5" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server not disabling MD5 ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u  | grep -q -E -v "^([[:space:]])?#" || true)")")"
      fi

      # lighttpd implicitly applies ssl.cipher-list = "HIGH" (since lighttpd 1.4.54) if ssl.cipher-list is not explicitly set in lighttpd.conf.
      print_output "[*] Testing web server LOW ciphers"
      if grep -E "ssl.cipher-list.*:LOW" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server enabling LOW ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u  | grep -q -E -v "^([[:space:]])?#" || true)")")"
      fi
      print_output "[*] Testing web server MEDIUM ciphers"
      if grep -E "ssl.cipher-list.*:MEDIUM" "${lLIGHTTPD_CONFIG}" | grep -q -E -v "^([[:space:]])?#"; then
        print_output "[+] Possible configuration issue detected: ${ORANGE}Web server enabling MEDIUM ciphers.${NC}"
        print_output "$(indent "$(orange "$(grep "ssl.cipher-list" "${lLIGHTTPD_CONFIG}" | sort -u  | grep -q -E -v "^([[:space:]])?#" || true)")")"
      fi
    fi
  fi
}
