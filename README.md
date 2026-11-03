# dualroute — установщик

Установка dualroute на роутер с OpenWrt 25.12 одной командой — в консоли роутера (`ssh root@192.168.1.1`):

```
sh <(wget -O - https://raw.githubusercontent.com/LEH1CH/dualroute-install/main/install.sh)
```

Сам dualroute лежит в приватном репозитории: ставить его могут только те, кого туда пригласили. Скрипт спросит
токен GitHub — Tokens (classic) с правом `repo`:
https://github.com/settings/tokens/new?scopes=repo&description=dualroute. Без доступа к репозиторию он ничего не
скачает. Токен остаётся на роутере (файл с правами 600) для обновлений кнопкой в LuCI.

Параметры (после команды): `--corp` — ещё корп. VPN, `--xray` — ещё Xray, `--no-zapret` — без обхода DPI.
Повторный запуск обновляет dualroute до последнего релиза, настройки остаются.
