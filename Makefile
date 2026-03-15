.PHONY: check lint install-deps

check:
	@bash scripts/check.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "请先安装 shellcheck: apt-get install shellcheck"; exit 1; }
	@shellcheck -S warning --exclude=SC1090,SC1091,SC2034 \
		flyto.sh install.sh \
		modules/hk-setup.sh modules/warp.sh \
		tools/gen-secrets.sh \
		lib/ui.sh lib/validate.sh lib/progress.sh lib/error.sh \
		scripts/check.sh

install-deps:
	@apt-get install -y dialog shellcheck
