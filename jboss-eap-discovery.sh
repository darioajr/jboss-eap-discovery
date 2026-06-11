#!/usr/bin/env bash

# ==============================================================================
# JBoss EAP 6/7/8 Discovery Script
# ==============================================================================
#
# Compatível com RHEL 6/7/8.
#
# Não usa:
# - jq
# - xmlstarlet
# - lsof
# - python
# - perl
#
# Saídas:
#   texto padrão:
#     ./jboss-eap-discovery.sh
#
#   JSON:
#     ./jboss-eap-discovery.sh --json
#
# ==============================================================================

set -u

OUTPUT_FORMAT="text"

for arg in "$@"; do
  case "$arg" in
    --json)
      OUTPUT_FORMAT="json"
      ;;
    --help|-h)
      echo "Uso: $0 [--json]"
      echo
      echo "Variáveis opcionais:"
      echo "  SEARCH_ROOTS=\"/opt /jboss /u01 /apps\""
      echo "  MAXDEPTH=12"
      exit 0
      ;;
  esac
done

SEARCH_ROOTS="${SEARCH_ROOTS:-/opt /jboss /app /apps /srv /usr/local /home /u01}"
MAXDEPTH="${MAXDEPTH:-8}"

TMP_HOME="/tmp/jboss_eap_home_$$.tmp"
TMP_DEPLOYED="/tmp/jboss_eap_deployed_$$.tmp"
TMP_FOUND="/tmp/jboss_eap_found_$$.tmp"

: > "$TMP_HOME"
: > "$TMP_DEPLOYED"
: > "$TMP_FOUND"

cleanup() {
  rm -f "$TMP_HOME" "$TMP_DEPLOYED" "$TMP_FOUND"
}

trap cleanup EXIT

print_line() {
  printf '%*s\n' "${COLUMNS:-120}" '' | tr ' ' '-'
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

json_escape() {
  # Escape básico suficiente para caminhos, comandos e nomes comuns.
  # Não depende de jq/python/perl.
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/	/\\t/g' \
    -e 's/\r/\\r/g'
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

json_kv() {
  key="$1"
  value="$2"
  printf '"%s":' "$(json_escape "$key")"
  json_string "$value"
}

get_os_hostname() {
  hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown"
}

get_os_fqdn() {
  hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown"
}

extract_arg_value() {
  echo "$1" | sed -n "s#.*$2\([^ ]*\).*#\1#p" | head -n 1
}

get_process_host_name() {
  args="$1"

  host_name="$(echo "$args" | sed -n 's#.*-Djboss.host.name=\([^ ]*\).*#\1#p' | head -n 1)"

  if [ -z "$host_name" ]; then
    host_name="$(echo "$args" | sed -n 's#.*-Djboss.qualified.host.name=\([^ ]*\).*#\1#p' | head -n 1)"
  fi

  echo "$host_name"
}

discover_from_processes() {
  ps -eo pid=,args= 2>/dev/null | \
  grep -E 'jboss|wildfly|org\.jboss|jboss-modules\.jar|standalone\.sh|domain\.sh' | \
  grep -v grep |
  while read -r pid args; do
    home=""
    mode="unknown"
    host_config=""
    server_config=""
    process_host_name=""

    home="$(extract_arg_value "$args" "-Djboss.home.dir=")"

    if [ -z "$home" ]; then
      home="$(extract_arg_value "$args" "-Dwildfly.home.dir=")"
    fi

    if [ -z "$home" ]; then
      home="$(echo "$args" | sed -n 's#.*\(/[^ ]*/bin/\(standalone\|domain\)\.sh\).*#\1#p' | sed 's#/bin/.*##' | head -n 1)"
    fi

    if echo "$args" | grep -q 'standalone'; then
      mode="standalone"
    fi

    if echo "$args" | grep -q 'domain'; then
      mode="domain"
    fi

    server_config="$(echo "$args" | sed -n 's#.*--server-config=\([^ ]*\).*#\1#p' | head -n 1)"
    host_config="$(echo "$args" | sed -n 's#.*--host-config=\([^ ]*\).*#\1#p' | head -n 1)"
    process_host_name="$(get_process_host_name "$args")"

    if [ -n "$home" ] && [ -d "$home" ]; then
      echo "$home|process|$pid|$mode|$server_config|$host_config|$process_host_name" >> "$TMP_HOME"
    fi
  done
}

discover_from_find() {
  for root in $SEARCH_ROOTS; do
    [ -d "$root" ] || continue

    find "$root" -maxdepth "$MAXDEPTH" \
      \( -name "jboss-modules.jar" -o -path "*/bin/standalone.sh" -o -path "*/bin/domain.sh" \) \
      2>/dev/null |
    while read -r found; do
      case "$found" in
        */jboss-modules.jar)
          home="$(dirname "$found")"
          ;;
        */bin/standalone.sh|*/bin/domain.sh)
          home="$(dirname "$(dirname "$found")")"
          ;;
        *)
          home=""
          ;;
      esac

      if [ -n "$home" ] && [ -d "$home" ]; then
        echo "$home|find|-|unknown|||" >> "$TMP_HOME"
      fi
    done
  done
}

detect_version() {
  home="$1"

  if [ -f "$home/version.txt" ]; then
    head -n 1 "$home/version.txt" 2>/dev/null
    return
  fi

  if [ -f "$home/bin/product.conf" ]; then
    grep -E 'slot=|product=' "$home/bin/product.conf" 2>/dev/null | tr '\n' ' '
    return
  fi

  echo "unknown"
}

detect_mode_by_files() {
  home="$1"
  hinted_mode="$2"

  if [ "$hinted_mode" = "standalone" ] || [ "$hinted_mode" = "domain" ]; then
    echo "$hinted_mode"
    return
  fi

  has_standalone="no"
  has_domain="no"

  [ -f "$home/bin/standalone.sh" ] && [ -d "$home/standalone/configuration" ] && has_standalone="yes"
  [ -f "$home/bin/domain.sh" ] && [ -d "$home/domain/configuration" ] && has_domain="yes"

  if [ "$has_standalone" = "yes" ] && [ "$has_domain" = "yes" ]; then
    echo "both-installed"
    return
  fi

  if [ "$has_standalone" = "yes" ]; then
    echo "standalone"
    return
  fi

  if [ "$has_domain" = "yes" ]; then
    echo "domain"
    return
  fi

  echo "unknown"
}

resolve_host_xml() {
  home="$1"
  host_config="$2"

  if [ -n "$host_config" ]; then
    if [ -f "$host_config" ]; then
      echo "$host_config"
      return
    fi

    if [ -f "$home/domain/configuration/$host_config" ]; then
      echo "$home/domain/configuration/$host_config"
      return
    fi
  fi

  if [ -f "$home/domain/configuration/host.xml" ]; then
    echo "$home/domain/configuration/host.xml"
    return
  fi

  ls "$home"/domain/configuration/host*.xml 2>/dev/null | head -n 1
}

get_host_name_from_xml() {
  host_xml="$1"

  if [ ! -f "$host_xml" ]; then
    echo ""
    return
  fi

  grep -E '<host[[:space:]]+.*name="' "$host_xml" 2>/dev/null | \
    head -n 1 | \
    sed -n 's/.*name="\([^"]*\)".*/\1/p'
}

resolve_jboss_domain_host_name() {
  home="$1"
  host_config="$2"
  process_host_name="$3"

  if [ -n "$process_host_name" ]; then
    echo "$process_host_name"
    return
  fi

  host_xml="$(resolve_host_xml "$home" "$host_config")"

  if [ -f "$host_xml" ]; then
    xml_host_name="$(get_host_name_from_xml "$host_xml")"

    if [ -n "$xml_host_name" ]; then
      echo "$xml_host_name"
      return
    fi
  fi

  get_os_hostname
}

detect_domain_role() {
  home="$1"
  host_config="$2"
  process_mode="$3"

  host_xml="$(resolve_host_xml "$home" "$host_config")"

  if [ ! -f "$host_xml" ]; then
    echo "unknown"
    return
  fi

  domain_controller_block="$(sed -n '/<domain-controller/,/<\/domain-controller>/p' "$host_xml" 2>/dev/null | tr '\n' ' ')"

  if echo "$domain_controller_block" | grep -q '<local[ />]'; then
    echo "master/primary"
    return
  fi

  if echo "$domain_controller_block" | grep -q '<remote[ />]'; then
    echo "slave/secondary"
    return
  fi

  if grep -q 'jboss.domain.master.address' "$host_xml" 2>/dev/null; then
    echo "slave/secondary"
    return
  fi

  if [ "$process_mode" = "domain" ]; then
    echo "domain-role-unknown"
  else
    echo "not-domain"
  fi
}

get_standalone_xmls() {
  home="$1"

  for f in "$home/standalone/configuration/"*.xml; do
    [ -f "$f" ] && echo "$f"
  done
}

get_domain_xmls() {
  home="$1"

  for f in "$home/domain/configuration/"*.xml; do
    [ -f "$f" ] && echo "$f"
  done
}

detect_marker_status() {
  artifact="$1"

  dir="$(dirname "$artifact")"
  name="$(basename "$artifact")"

  if [ -f "$dir/$name.deployed" ]; then
    echo "DEPLOYED"
    return
  fi

  if [ -f "$dir/$name.failed" ]; then
    echo "FAILED"
    return
  fi

  if [ -f "$dir/$name.undeployed" ]; then
    echo "UNDEPLOYED"
    return
  fi

  if [ -f "$dir/$name.isdeploying" ]; then
    echo "DEPLOYING"
    return
  fi

  if [ -f "$dir/$name.isundeploying" ]; then
    echo "UNDEPLOYING"
    return
  fi

  if [ -f "$dir/$name.dodeploy" ]; then
    echo "PENDING"
    return
  fi

  echo "UNKNOWN"
}

extract_attr() {
  line="$1"
  attr="$2"

  echo "$line" | sed -n "s/.*$attr=\"\([^\"]*\)\".*/\1/p" | head -n 1
}

collect_declared_apps_from_xml() {
  home="$1"
  mode="$2"

  : > "$TMP_DEPLOYED"

  xmls=""

  case "$mode" in
    standalone)
      xmls="$(get_standalone_xmls "$home")"
      ;;
    domain)
      xmls="$(get_domain_xmls "$home")"
      ;;
    both-installed)
      xmls="$(get_standalone_xmls "$home")
$(get_domain_xmls "$home")"
      ;;
    *)
      xmls="$(get_standalone_xmls "$home")
$(get_domain_xmls "$home")"
      ;;
  esac

  echo "$xmls" | while read -r xml; do
    [ -f "$xml" ] || continue

    server_group=""

    while IFS= read -r line; do
      if echo "$line" | grep -q '<server-group[[:space:]]'; then
        sg_name="$(extract_attr "$line" "name")"
        [ -n "$sg_name" ] && server_group="$sg_name"
      fi

      if echo "$line" | grep -q '</server-group>'; then
        server_group=""
      fi

      echo "$line" | grep -Eq '<deployment[[:space:]][^>]*name="[^"]*\.(war|ear)"' || continue

      app="$(extract_attr "$line" "name")"
      runtime_name="$(extract_attr "$line" "runtime-name")"
      enabled="$(extract_attr "$line" "enabled")"

      [ -n "$app" ] || continue

      case "$app" in
        *.war|*.ear)
          ;;
        *)
          continue
          ;;
      esac

      [ -z "$runtime_name" ] && runtime_name="$app"

      scope="top-level"

      if [ -n "$server_group" ]; then
        scope="server-group:$server_group"
      fi

      status="DECLARED"

      if [ "$enabled" = "false" ]; then
        status="NOT_DEPLOYED"
      elif [ "$enabled" = "true" ]; then
        status="DEPLOYED"
      elif [ "$mode" = "standalone" ]; then
        status="DEPLOYED"
      elif [ -n "$server_group" ]; then
        status="DEPLOYED"
      else
        status="DECLARED"
      fi

      echo "$app|$runtime_name|$status|xml|$xml|$scope" >> "$TMP_DEPLOYED"
    done < "$xml"
  done

  sort -u "$TMP_DEPLOYED" -o "$TMP_DEPLOYED"
}

collect_physical_apps() {
  home="$1"

  : > "$TMP_FOUND"

  find "$home" \
    \( -path "$home/.git" -o -path "$home/tmp" -o -path "$home/docs" \) -prune -o \
    \( \
      -type f -name "*.war" -o \
      -type d -name "*.war" -o \
      -type f -name "*.ear" -o \
      -type d -name "*.ear" \
    \) -print \
    2>/dev/null |
  sort |
  while read -r artifact; do
    name="$(basename "$artifact")"
    marker_status="$(detect_marker_status "$artifact")"
    echo "$name|$artifact|$marker_status" >> "$TMP_FOUND"
  done

  sort -u "$TMP_FOUND" -o "$TMP_FOUND"
}

is_declared_app() {
  app_name="$1"

  grep -Fq "$app_name|" "$TMP_DEPLOYED" 2>/dev/null
}

get_declared_status() {
  app_name="$1"

  grep -F "$app_name|" "$TMP_DEPLOYED" 2>/dev/null | head -n 1 | cut -d'|' -f3
}

get_final_physical_status() {
  app="$1"
  marker_status="$2"

  final_status="$marker_status"

  if is_declared_app "$app"; then
    declared_status="$(get_declared_status "$app")"

    case "$marker_status" in
      DEPLOYED|FAILED|UNDEPLOYED|DEPLOYING|UNDEPLOYING|PENDING)
        final_status="$marker_status"
        ;;
      *)
        final_status="$declared_status"
        ;;
    esac
  else
    case "$marker_status" in
      DEPLOYED|FAILED|UNDEPLOYED|DEPLOYING|UNDEPLOYING|PENDING)
        final_status="$marker_status"
        ;;
      *)
        final_status="NOT_DEPLOYED"
        ;;
    esac
  fi

  echo "$final_status"
}

get_processes_for_home_json() {
  home="$1"

  first="yes"

  printf '['

  ps -eo pid=,args= 2>/dev/null | grep "$home" | grep -v grep |
  while read -r line; do
    pid="$(echo "$line" | awk '{print $1}')"
    args="$(echo "$line" | cut -d' ' -f2- | sed 's/[[:space:]][[:space:]]*/ /g')"

    [ "$first" = "no" ] && printf ','
    first="no"

    printf '{'
    json_kv "pid" "$pid"
    printf ','
    json_kv "args" "$args"
    printf '}'
  done

  printf ']'
}

get_deployment_dirs_json() {
  home="$1"

  candidates="
$home/standalone/deployments
$home/domain/deployments
$home/domain/data/content
"

  first="yes"

  printf '['

  echo "$candidates" | while read -r d; do
    [ -d "$d" ] || continue

    [ "$first" = "no" ] && printf ','
    first="no"

    json_string "$d"
  done

  printf ']'
}

get_declared_apps_json() {
  first="yes"

  printf '['

  if [ -s "$TMP_DEPLOYED" ]; then
    while IFS='|' read -r app runtime status source_type source_file scope; do
      ext="${app##*.}"
      ext="$(lower "$ext")"

      [ "$first" = "no" ] && printf ','
      first="no"

      printf '{'
      json_kv "status" "$status"
      printf ','
      json_kv "name" "$app"
      printf ','
      json_kv "runtime_name" "$runtime"
      printf ','
      json_kv "type" "$ext"
      printf ','
      json_kv "source_type" "$source_type"
      printf ','
      json_kv "source" "$source_file"
      printf ','
      json_kv "scope" "$scope"
      printf '}'
    done < "$TMP_DEPLOYED"
  fi

  printf ']'
}

get_physical_apps_json() {
  first="yes"

  printf '['

  if [ -s "$TMP_FOUND" ]; then
    while IFS='|' read -r app path marker_status; do
      ext="${app##*.}"
      ext="$(lower "$ext")"
      final_status="$(get_final_physical_status "$app" "$marker_status")"

      [ "$first" = "no" ] && printf ','
      first="no"

      printf '{'
      json_kv "status" "$final_status"
      printf ','
      json_kv "marker_status" "$marker_status"
      printf ','
      json_kv "name" "$app"
      printf ','
      json_kv "type" "$ext"
      printf ','
      json_kv "path" "$path"
      printf '}'
    done < "$TMP_FOUND"
  fi

  printf ']'
}

get_missing_declared_json() {
  first="yes"

  printf '['

  if [ -s "$TMP_DEPLOYED" ]; then
    while IFS='|' read -r app runtime status source_type source_file scope; do
      if ! grep -Fq "$app|" "$TMP_FOUND" 2>/dev/null; then
        ext="${app##*.}"
        ext="$(lower "$ext")"

        [ "$first" = "no" ] && printf ','
        first="no"

        printf '{'
        json_kv "status" "$status"
        printf ','
        json_kv "name" "$app"
        printf ','
        json_kv "runtime_name" "$runtime"
        printf ','
        json_kv "type" "$ext"
        printf ','
        json_kv "source" "$source_file"
        printf ','
        json_kv "scope" "$scope"
        printf '}'
      fi
    done < "$TMP_DEPLOYED"
  fi

  printf ']'
}

print_processes_for_home_text() {
  home="$1"

  echo "Processos relacionados:"

  count="$(ps -eo pid=,args= 2>/dev/null | grep "$home" | grep -v grep | wc -l | awk '{print $1}')"

  if [ "$count" = "0" ]; then
    echo "  - Nenhum processo rodando encontrado para este JBOSS_HOME."
    return
  fi

  ps -eo pid=,args= 2>/dev/null | grep "$home" | grep -v grep |
  while read -r line; do
    echo "  - PID $(echo "$line" | awk '{print $1}')"
    echo "    $(echo "$line" | cut -d' ' -f2- | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-220)"
  done
}

list_deployment_dirs_text() {
  home="$1"

  echo "Diretórios prováveis de deployment:"

  candidates="
$home/standalone/deployments
$home/domain/deployments
$home/domain/data/content
"

  found="no"

  echo "$candidates" | while read -r d; do
    if [ -d "$d" ]; then
      found="yes"
      echo "  - $d"
    fi
  done
}

print_apps_report_text() {
  home="$1"
  mode="$2"

  collect_declared_apps_from_xml "$home" "$mode"
  collect_physical_apps "$home"

  echo "Aplicações WAR/EAR publicadas/deployadas ou declaradas:"
  printf "  %-14s %-50s %-10s %-25s %s\n" "STATUS" "APP" "TIPO" "ESCOPO" "ORIGEM"
  printf "  %-14s %-50s %-10s %-25s %s\n" "------" "---" "----" "------" "------"

  if [ ! -s "$TMP_DEPLOYED" ]; then
    echo "  Nenhum .war/.ear declarado nos XMLs."
  else
    while IFS='|' read -r app runtime status source_type source_file scope; do
      ext="${app##*.}"
      ext="$(lower "$ext")"
      printf "  %-14s %-50s %-10s %-25s %s\n" "$status" "$app" "$ext" "$scope" "$source_file"
    done < "$TMP_DEPLOYED"
  fi

  echo
  echo "Aplicações WAR/EAR encontradas fisicamente no disco:"
  printf "  %-14s %-14s %-50s %-10s %s\n" "STATUS" "MARKER" "APP" "TIPO" "CAMINHO"
  printf "  %-14s %-14s %-50s %-10s %s\n" "------" "------" "---" "----" "-------"

  if [ ! -s "$TMP_FOUND" ]; then
    echo "  Nenhum arquivo/diretório .war/.ear físico encontrado."
  else
    while IFS='|' read -r app path marker_status; do
      ext="${app##*.}"
      ext="$(lower "$ext")"
      final_status="$(get_final_physical_status "$app" "$marker_status")"

      printf "  %-14s %-14s %-50s %-10s %s\n" "$final_status" "$marker_status" "$app" "$ext" "$path"
    done < "$TMP_FOUND"
  fi

  echo
  echo "Aplicações declaradas no XML mas sem arquivo .war/.ear físico visível pelo nome:"
  printf "  %-14s %-50s %-10s %-25s %s\n" "STATUS" "APP" "TIPO" "ESCOPO" "ORIGEM"
  printf "  %-14s %-50s %-10s %-25s %s\n" "------" "---" "----" "------" "------"

  missing="no"

  if [ -s "$TMP_DEPLOYED" ]; then
    while IFS='|' read -r app runtime status source_type source_file scope; do
      if ! grep -Fq "$app|" "$TMP_FOUND" 2>/dev/null; then
        missing="yes"
        ext="${app##*.}"
        ext="$(lower "$ext")"
        printf "  %-14s %-50s %-10s %-25s %s\n" "$status" "$app" "$ext" "$scope" "$source_file"
      fi
    done < "$TMP_DEPLOYED"
  fi

  if [ "$missing" = "no" ]; then
    echo "  Nenhum caso encontrado."
  fi
}

print_text_output() {
  homes="$1"

  echo
  print_line
  echo "JBoss EAP 6/7/8 Discovery"
  print_line
  echo "Data: $(date)"
  echo "Roots pesquisados: $SEARCH_ROOTS"
  echo "Profundidade find: $MAXDEPTH"
  echo "Host SO: $(get_os_hostname)"
  echo "Host FQDN SO: $(get_os_fqdn)"
  echo

  for home in $homes; do
    records="$(grep "^$home|" "$TMP_HOME")"

    first_record="$(echo "$records" | head -n 1)"
    source="$(echo "$first_record" | cut -d'|' -f2)"
    pid="$(echo "$first_record" | cut -d'|' -f3)"
    hinted_mode="$(echo "$first_record" | cut -d'|' -f4)"
    server_config="$(echo "$first_record" | cut -d'|' -f5)"
    host_config="$(echo "$first_record" | cut -d'|' -f6)"
    process_host_name="$(echo "$first_record" | cut -d'|' -f7)"

    process_mode="$(echo "$records" | awk -F'|' '$4=="domain" || $4=="standalone" {print $4; exit}')"

    if [ -z "$process_mode" ]; then
      process_mode="$hinted_mode"
    fi

    mode="$(detect_mode_by_files "$home" "$process_mode")"
    version="$(detect_version "$home")"

    case "$mode" in
      domain|both-installed)
        role="$(detect_domain_role "$home" "$host_config" "$process_mode")"
        ;;
      standalone)
        role="standalone"
        ;;
      *)
        role="unknown"
        ;;
    esac

    os_hostname="$(get_os_hostname)"
    os_fqdn="$(get_os_fqdn)"
    jboss_domain_host="$(resolve_jboss_domain_host_name "$home" "$host_config" "$process_host_name")"
    resolved_host_xml="$(resolve_host_xml "$home" "$host_config")"

    print_line
    echo "JBOSS_HOME: $home"
    echo "Host SO: $os_hostname"
    echo "Host FQDN SO: $os_fqdn"
    echo "Host JBoss Domain: $jboss_domain_host"
    echo "Descoberto por: $source"
    echo "PID exemplo: $pid"
    echo "Versão/produto: $version"
    echo "Modo detectado: $mode"
    echo "Papel no domain: $role"

    if [ "$mode" = "domain" ] || [ "$mode" = "both-installed" ]; then
      [ -n "$resolved_host_xml" ] && echo "Host XML: $resolved_host_xml"
    fi

    [ -n "$server_config" ] && echo "Server config pelo processo: $server_config"
    [ -n "$host_config" ] && echo "Host config pelo processo: $host_config"

    echo
    print_processes_for_home_text "$home"

    echo
    list_deployment_dirs_text "$home"

    echo
    print_apps_report_text "$home" "$mode"

    echo
  done

  print_line
  echo "Legenda:"
  echo "  DEPLOYED       = Aplicação publicada/deployada."
  echo "  DECLARED       = Declarada no XML, mas sem confirmação clara de publicação em server-group."
  echo "  NOT_DEPLOYED   = Arquivo .war/.ear encontrado no disco, mas não declarado/publicado."
  echo "  PENDING        = Existe marcador .dodeploy."
  echo "  FAILED         = Existe marcador .failed."
  echo "  UNDEPLOYED     = Existe marcador .undeployed."
  echo "  DEPLOYING      = Existe marcador .isdeploying."
  echo "  UNDEPLOYING    = Existe marcador .isundeploying."
  echo "  UNKNOWN        = Encontrado no disco, mas sem marcador e sem declaração clara."
  echo
  echo "Observações:"
  echo "  - Em standalone, aplicações em standalone.xml são consideradas DEPLOYED."
  echo "  - Em domain, aplicações em server-group são consideradas DEPLOYED quando enabled=true ou sem enabled=false."
  echo "  - Em domain, aplicações apenas no bloco top-level deployments aparecem como DECLARED."
  echo "  - Em domain/data/content, o conteúdo costuma estar por hash, sem o nome original do WAR/EAR."
  print_line
}

print_json_output() {
  homes="$1"

  printf '{'
  json_kv "generated_at" "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf ','
  json_kv "os_hostname" "$(get_os_hostname)"
  printf ','
  json_kv "os_fqdn" "$(get_os_fqdn)"
  printf ','
  printf '"search_roots":['

  first_root="yes"
  for root in $SEARCH_ROOTS; do
    [ "$first_root" = "no" ] && printf ','
    first_root="no"
    json_string "$root"
  done

  printf ']'
  printf ','
  json_kv "maxdepth" "$MAXDEPTH"
  printf ','
  printf '"installations":['

  first_home="yes"

  for home in $homes; do
    records="$(grep "^$home|" "$TMP_HOME")"

    first_record="$(echo "$records" | head -n 1)"
    source="$(echo "$first_record" | cut -d'|' -f2)"
    pid="$(echo "$first_record" | cut -d'|' -f3)"
    hinted_mode="$(echo "$first_record" | cut -d'|' -f4)"
    server_config="$(echo "$first_record" | cut -d'|' -f5)"
    host_config="$(echo "$first_record" | cut -d'|' -f6)"
    process_host_name="$(echo "$first_record" | cut -d'|' -f7)"

    process_mode="$(echo "$records" | awk -F'|' '$4=="domain" || $4=="standalone" {print $4; exit}')"

    if [ -z "$process_mode" ]; then
      process_mode="$hinted_mode"
    fi

    mode="$(detect_mode_by_files "$home" "$process_mode")"
    version="$(detect_version "$home")"

    case "$mode" in
      domain|both-installed)
        role="$(detect_domain_role "$home" "$host_config" "$process_mode")"
        ;;
      standalone)
        role="standalone"
        ;;
      *)
        role="unknown"
        ;;
    esac

    os_hostname="$(get_os_hostname)"
    os_fqdn="$(get_os_fqdn)"
    jboss_domain_host="$(resolve_jboss_domain_host_name "$home" "$host_config" "$process_host_name")"
    resolved_host_xml="$(resolve_host_xml "$home" "$host_config")"

    collect_declared_apps_from_xml "$home" "$mode"
    collect_physical_apps "$home"

    [ "$first_home" = "no" ] && printf ','
    first_home="no"

    printf '{'
    json_kv "jboss_home" "$home"
    printf ','
    json_kv "host_os" "$os_hostname"
    printf ','
    json_kv "host_fqdn_os" "$os_fqdn"
    printf ','
    json_kv "host_jboss_domain" "$jboss_domain_host"
    printf ','
    json_kv "discovered_by" "$source"
    printf ','
    json_kv "pid_example" "$pid"
    printf ','
    json_kv "version" "$version"
    printf ','
    json_kv "mode" "$mode"
    printf ','
    json_kv "domain_role" "$role"
    printf ','
    json_kv "host_xml" "$resolved_host_xml"
    printf ','
    json_kv "server_config" "$server_config"
    printf ','
    json_kv "host_config" "$host_config"
    printf ','
    printf '"processes":'
    get_processes_for_home_json "$home"
    printf ','
    printf '"deployment_dirs":'
    get_deployment_dirs_json "$home"
    printf ','
    printf '"apps_declared":'
    get_declared_apps_json
    printf ','
    printf '"apps_physical":'
    get_physical_apps_json
    printf ','
    printf '"apps_declared_without_visible_artifact":'
    get_missing_declared_json
    printf '}'
  done

  printf ']'
  printf '}'
  printf '\n'
}

main() {
  discover_from_processes
  discover_from_find

  homes="$(cut -d'|' -f1 "$TMP_HOME" | unique_lines)"

  if [ -z "$homes" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{'
      json_kv "generated_at" "$(date '+%Y-%m-%d %H:%M:%S %z')"
      printf ','
      json_kv "os_hostname" "$(get_os_hostname)"
      printf ','
      json_kv "os_fqdn" "$(get_os_fqdn)"
      printf ','
      printf '"installations":[]'
      printf ','
      json_kv "message" "Nenhuma instalação JBoss EAP encontrada."
      printf '}'
      printf '\n'
    else
      echo "Nenhuma instalação JBoss EAP encontrada."
      echo
      echo "Tente informar diretórios customizados:"
      echo "  SEARCH_ROOTS=\"/opt /jboss /u01 /apps\" ./jboss-eap-discovery.sh"
    fi

    exit 1
  fi

  if [ "$OUTPUT_FORMAT" = "json" ]; then
    print_json_output "$homes"
  else
    print_text_output "$homes"
  fi
}

main "$@"
