#!/bin/bash
set -e

CURSEFORGE_MOD_ID="925200"                       # Projekt-ID von "All the Mods 10"
NEOFORGE_VERSION="${NEOFORGE_VERSION:-21.1.224}" # Fallback, falls Auto-Erkennung fehlschlägt

cd /data

if ! [[ "$EULA" = "false" ]]; then
  echo "eula=true" > eula.txt
else
  echo "You must accept the EULA to install."
  exit 99
fi

if [[ -z "$CURSEFORGE_API_KEY" ]]; then
  echo "FEHLER: CURSEFORGE_API_KEY ist nicht gesetzt (Umgebungsvariable fehlt)."
  exit 98
fi

echo "Frage CurseForge API nach der neuesten Server-Datei ab..."
FILES_JSON=$(curl -sf -H "x-api-key: $CURSEFORGE_API_KEY" -H "Accept: application/json" \
  "https://api.curseforge.com/v1/mods/${CURSEFORGE_MOD_ID}/files?pageSize=50") || {
  echo "FEHLER: CurseForge API war nicht erreichbar."
  exit 97
}

# Von allen Dateien nur die "ServerFiles-*.zip" behalten und die neueste (nach Datum) nehmen
LATEST_FILE=$(echo "$FILES_JSON" | jq -c '
  [.data[] | select(.fileName | test("^ServerFiles-.*\\.zip$"))]
  | sort_by(.fileDate) | last
')

if [[ "$LATEST_FILE" == "null" || -z "$LATEST_FILE" ]]; then
  echo "FEHLER: Keine ServerFiles-*.zip bei CurseForge gefunden."
  exit 96
fi

SERVER_VERSION=$(echo "$LATEST_FILE" | jq -r '.fileName' | sed -E 's/^ServerFiles-(.*)\.zip$/\1/')
DOWNLOAD_URL=$(echo "$LATEST_FILE" | jq -r '.downloadUrl')
echo "Neueste verfügbare Version laut CurseForge: $SERVER_VERSION"

INSTALLED_VERSION_FILE="/data/.installed_server_version"
CURRENT_INSTALLED=""
[[ -f "$INSTALLED_VERSION_FILE" ]] && CURRENT_INSTALLED=$(cat "$INSTALLED_VERSION_FILE")

if [[ "$CURRENT_INSTALLED" != "$SERVER_VERSION" ]] || ! [[ -f run.sh ]]; then
  echo "Installiere/aktualisiere von '$CURRENT_INSTALLED' auf '$SERVER_VERSION' ..."
  rm -fr config defaultconfigs kubejs mods packmenu libraries neoforge*

  curl -Lo "ServerFiles-$SERVER_VERSION.zip" "$DOWNLOAD_URL" || exit 9
  unzip -u -o "ServerFiles-$SERVER_VERSION.zip" -d /data

  DIR_TEST=$(find . -maxdepth 1 -type d -iname "ServerFiles-*" | head -n1)
  if [[ -n "$DIR_TEST" ]]; then
    find "$DIR_TEST" -type d -exec chmod 777 {} +
    mv -f "$DIR_TEST"/* /data
    rm -fr "$DIR_TEST"
  fi

  # Versuch, die NeoForge-Version automatisch aus run.sh zu lesen
  if [[ -f run.sh ]]; then
    DETECTED=$(grep -oE 'neoforge/[0-9]+(\.[0-9]+)*' run.sh | head -n1 | cut -d'/' -f2)
    [[ -n "$DETECTED" ]] && NEOFORGE_VERSION="$DETECTED"
  fi

  echo "Installiere NeoForge $NEOFORGE_VERSION ..."
  curl -Lo "neoforge-${NEOFORGE_VERSION}-installer.jar" \
    "https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/neoforge-${NEOFORGE_VERSION}-installer.jar"
  java -jar "neoforge-${NEOFORGE_VERSION}-installer.jar" --installServer

  echo "$SERVER_VERSION" > "$INSTALLED_VERSION_FILE"
  rm -f "ServerFiles-$SERVER_VERSION.zip" "neoforge-${NEOFORGE_VERSION}-installer.jar"
else
  echo "Version $SERVER_VERSION ist bereits installiert, überspringe Download."
fi

if [[ -n "$JVM_OPTS" ]]; then
  sed -i '/-Xm[s,x]/d' user_jvm_args.txt
  for j in ${JVM_OPTS}; do sed -i '$a\'$j'' user_jvm_args.txt; done
fi

[[ -n "$MOTD" ]] && sed -i "s/^motd=.*/motd=$MOTD/" /data/server.properties
[[ -n "$ENABLE_WHITELIST" ]] && sed -i "s/white-list=.*/white-list=$ENABLE_WHITELIST/" /data/server.properties
[[ -n "$ALLOW_FLIGHT" ]] && sed -i "s/allow-flight=.*/allow-flight=$ALLOW_FLIGHT/" /data/server.properties
[[ -n "$MAX_PLAYERS" ]] && sed -i "s/max-players=.*/max-players=$MAX_PLAYERS/" /data/server.properties
[[ -n "$ONLINE_MODE" ]] && sed -i "s/online-mode=.*/online-mode=$ONLINE_MODE/" /data/server.properties

[[ ! -f whitelist.json ]] && echo "[]" > whitelist.json
IFS=',' read -ra USERS <<< "$WHITELIST_USERS"
for raw_username in "${USERS[@]}"; do
  username=$(echo "$raw_username" | xargs)
  [[ -z "$username" ]] || ! [[ "$username" =~ ^[a-zA-Z0-9_]{3,16}$ ]] && { echo "Whitelist: ungültig: '$username'. Skip."; continue; }
  UUID=$(curl -s "https://playerdb.co/api/player/minecraft/$username" | jq -r '.data.player.id')
  if [[ "$UUID" != "null" ]]; then
    if jq -e ".[] | select(.uuid == \"$UUID\" and .name == \"$username\")" whitelist.json > /dev/null; then
      echo "Whitelist: $username bereits vorhanden."
    else
      jq ". += [{\"uuid\": \"$UUID\", \"name\": \"$username\"}]" whitelist.json > tmp.json && mv tmp.json whitelist.json
    fi
  fi
done

[[ ! -f ops.json ]] && echo "[]" > ops.json
IFS=',' read -ra OPS <<< "$OP_USERS"
for raw_username in "${OPS[@]}"; do
  username=$(echo "$raw_username" | xargs)
  [[ -z "$username" ]] || ! [[ "$username" =~ ^[a-zA-Z0-9_]{3,16}$ ]] && { echo "Ops: ungültig: '$username'. Skip."; continue; }
  UUID=$(curl -s "https://playerdb.co/api/player/minecraft/$username" | jq -r '.data.player.id')
  if [[ "$UUID" != "null" ]]; then
    if jq -e ".[] | select(.uuid == \"$UUID\" and .name == \"$username\")" ops.json > /dev/null; then
      echo "Ops: $username bereits vorhanden."
    else
      jq ". += [{\"uuid\": \"$UUID\", \"name\": \"$username\", \"level\": 4, \"bypassesPlayerLimit\": false}]" ops.json > tmp.json && mv tmp.json ops.json
    fi
  fi
done

sed -i 's/server-port.*/server-port=25565/g' server.properties
chmod 755 run.sh
./run.sh
