#!/bin/sh
# dualroute: установка одной командой на роутер с OpenWrt 25.12 (пакеты apk) — в консоли роутера (ssh root@192.168.1.1):
#
#     sh <(wget -O - https://raw.githubusercontent.com/LEH1CH/dualroute-install/main/install.sh)
#
# Пакеты лежат в приватном репозитории LEH1CH/dualroute-openwrt, поэтому скрипт спрашивает токен GitHub того, кого
# туда пригласили: Tokens (classic) с правом repo — https://github.com/settings/tokens/new?scopes=repo&description=dualroute
# (fine-grained токен чужой репозиторий не видит). Токен не печатается и не попадает в список процессов (curl
# читает заголовок из файла с правами 600); после установки он остаётся на роутере для страницы «Обновления».
# Без доступа к репозиторию скрипт ничего не скачает. Токен можно передать и так: DUALROUTE_TOKEN=… sh install.sh
#
# Что делает: проверяет OpenWrt и архитектуру пакетов (/etc/apk/arch), ставит curl, скачивает последний релиз
# (release.json, SHA256SUMS.txt) и пакеты под эту архитектуру, сверяет контрольные суммы, останавливает podkop
# (до перезагрузки — перенос его настроек делается в LuCI), ставит пакеты (зависимости — из репозитория OpenWrt).
# Повторный запуск обновляет до последнего релиза, настройки остаются.
#
# Параметры: --corp — ещё корп. VPN (dualroute-corp); --xray — ещё Xray (около 30 МБ на флеше, для ссылок VLESS с
# XHTTP или VLESS Encryption); --no-zapret — без обхода DPI.
#
# Этот файл — копия tools/install/install.sh из LEH1CH/dualroute-openwrt; правится там.

REPO=LEH1CH/dualroute-openwrt
API=${DUALROUTE_API:-https://api.github.com}   # другой адрес — только для проверки на макете
WORK=/tmp/dualroute-install
TOKEN_FILE=/etc/dualroute/github.token

say() { echo "$*"; }
die() { echo "ОШИБКА: $*" >&2; rm -rf "$WORK"; exit 1; }

ZAPRET="dualroute-zapret2 dualroute-zapret1"
EXTRA=""
for a in "$@"; do
	case "$a" in
	--corp) EXTRA="$EXTRA dualroute-corp" ;;
	--xray) EXTRA="$EXTRA dualroute-xray" ;;
	--no-zapret) ZAPRET="" ;;
	*) die "непонятный параметр $a (есть --corp, --xray, --no-zapret)" ;;
	esac
done
WANT="dualroute luci-app-dualroute $ZAPRET $EXTRA"

[ "$(id -u)" = 0 ] || die "запускать от root"
[ -f /etc/openwrt_release ] || die "это не OpenWrt"
. /etc/openwrt_release
command -v apk >/dev/null || die "нужна OpenWrt 25.12 или новее (пакеты apk), здесь ${DISTRIB_RELEASE:-?}. Обновление прошивки — docs/install.md, «Способ 1»"
ARCH=$(head -n 1 /etc/apk/arch 2>/dev/null)
[ -n "$ARCH" ] || die "не удалось узнать архитектуру пакетов (/etc/apk/arch)"
say "Роутер: $(cat /tmp/sysinfo/model 2>/dev/null), OpenWrt $DISTRIB_RELEASE, пакеты $ARCH"

rm -rf "$WORK"
mkdir -p "$WORK" && chmod 700 "$WORK" || die "не создать $WORK"
trap 'stty echo 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

say "Обновляю список пакетов OpenWrt…"
apk update >/dev/null 2>&1 || die "apk update не прошёл — есть ли интернет на роутере?"
command -v curl >/dev/null || apk add curl >/dev/null 2>&1 || die "не ставится curl"

# Токен: сохранённый (повторная установка), из DUALROUTE_TOKEN или спросить
HDR="$WORK/token"
if [ -z "$DUALROUTE_TOKEN" ] && [ -s "$TOKEN_FILE" ]; then
	(umask 077; cp "$TOKEN_FILE" "$HDR")
	say "Токен GitHub — сохранённый на роутере"
else
	t=$DUALROUTE_TOKEN
	if [ -z "$t" ]; then
		say ""
		say "Нужен токен GitHub с доступом к $REPO (вас должны пригласить в репозиторий):"
		say "  https://github.com/settings/tokens/new?scopes=repo&description=dualroute — Tokens (classic), право repo"
		printf "Токен (ввод не виден): "
		stty -echo 2>/dev/null </dev/tty
		read -r t </dev/tty
		stty echo 2>/dev/null </dev/tty
		echo
	fi
	t=$(echo "$t" | tr -d ' \r\n')
	echo "$t" | grep -Eq '^[A-Za-z0-9_]{20,255}$' || die "токен GitHub — строка вида ghp_… или github_pat_…"
	(umask 077; echo "Authorization: Bearer $t" > "$HDR")
	t=
fi

# Запрос к API GitHub: gh <url> <accept> <файл>
gh() {
	code=$(curl -sS -L -m 120 -H @"$HDR" -H "Accept: $2" -H 'X-GitHub-Api-Version: 2022-11-28' -A dualroute-install \
		-o "$3" -w '%{http_code}' "$1" 2>"$WORK/curl.err")
	case "$code" in
	200) return 0 ;;
	401) die "токен GitHub не принят — создайте новый" ;;
	403|404) die "нет доступа к $REPO: у токена нет права repo или вас не пригласили в репозиторий (код $code)" ;;
	000) die "нет связи с GitHub: $(cat "$WORK/curl.err")" ;;
	*) die "GitHub ответил кодом $code" ;;
	esac
}

say "Ищу последний релиз dualroute…"
gh "$API/repos/$REPO/releases/latest" application/vnd.github+json "$WORK/rel.json"
VERSION=$(jsonfilter -i "$WORK/rel.json" -e '@.tag_name')
[ -n "$VERSION" ] || die "ответ GitHub не похож на релиз"
asset() { jsonfilter -i "$WORK/rel.json" -e "@.assets[@.name='$1'].url"; }
for f in release.json SHA256SUMS.txt; do
	u=$(asset "$f")
	[ -n "$u" ] || die "в релизе $VERSION нет $f"
	gh "$u" application/octet-stream "$WORK/$f"
done

FILES=""
for n in $WANT; do
	file=$(jsonfilter -i "$WORK/release.json" -e "@.packages[@.name='$n' && @.arch='$ARCH'].file")
	[ -n "$file" ] || file=$(jsonfilter -i "$WORK/release.json" -e "@.packages[@.name='$n' && @.arch='all'].file")
	if [ -z "$file" ]; then
		case "$n" in
		dualroute-zapret*) say "  $n: в релизе нет сборки под $ARCH — без него (обход DPI через другой движок или VPN)"; continue ;;
		*) die "в релизе $VERSION нет пакета $n" ;;
		esac
	fi
	u=$(asset "$file")
	[ -n "$u" ] || die "в релизе нет файла $file"
	say "  скачиваю $file"
	gh "$u" application/octet-stream "$WORK/$file"
	sum=$(grep "  $file\$" "$WORK/SHA256SUMS.txt" | cut -d' ' -f1)
	[ -n "$sum" ] && [ "$(sha256sum "$WORK/$file" | cut -d' ' -f1)" = "$sum" ] ||
		die "$file: контрольная сумма не совпала — файл повреждён"
	FILES="$FILES $WORK/$file"
done

# podkop и dualroute вместе не работают (оба перехватывают трафик и DNS); stop возвращает dnsmasq как было.
# Не disable: до переноса перезагрузка вернёт podkop, перенос («Обзор» → «Перенести») выключит его совсем
PODKOP=
if [ -x /etc/init.d/podkop ]; then
	/etc/init.d/podkop stop >/dev/null 2>&1 && say "podkop остановлен (до перезагрузки)"
	[ -f /etc/config/podkop ] && PODKOP=1
fi

say "Ставлю dualroute ${VERSION#v} (зависимости — из репозитория OpenWrt, до нескольких минут)…"
# shellcheck disable=SC2086
apk add --allow-untrusted $FILES || die "apk add не прошёл — подробности выше; повторить — та же команда"

mkdir -p /etc/dualroute
(umask 077; cp "$HDR" "$TOKEN_FILE.new") && mv "$TOKEN_FILE.new" "$TOKEN_FILE"

LAN=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
say ""
apk info -v 2>/dev/null | grep -E '^(luci-app-)?dualroute' | sed 's/^/  /'
say ""
say "Готово: dualroute ${VERSION#v} стоит. LuCI: http://${LAN:-192.168.1.1} → Службы → dualroute"
if [ -n "$PODKOP" ]; then
	say "podkop остановлен до перезагрузки — пока его настройки не перенесены, VPN не работает (интернет идёт напрямую)."
	say "Перенести профили, сервисы и свои списки: «Обзор» → «Найдены настройки podkop» → «Перенести»."
else
	say "Дальше: «Профили» → «Добавить по ссылке» (vless://, hy2://, trojan://, ss://) или «Подписка», потом включить на «Обзоре»."
fi
say "Обновления — кнопкой на странице «Обновления»: токен уже сохранён на роутере."
