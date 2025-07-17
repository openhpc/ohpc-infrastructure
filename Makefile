lint: codespell-lint whitespace-lint shellcheck-lint shfmt-lint ansible-lint ruff-lint

codespell-lint:
	@echo "Running 'codespell' on all files"
		codespell . \

whitespace-lint:
	@echo "Checking all files for trailing whitespaces"
		! git --no-pager grep -I -E '\s+$$'

shellcheck-lint:
	@echo "Running 'shellcheck' on all shell scripts"
	shellcheck \
		-o quote-safe-variables,deprecate-which,avoid-nullary-conditions \
		$$(find . -name *sh)

shfmt-lint:
	@echo "Running 'shfmt' on all shell scripts"
	shfmt -w -d \
		$$(find . -name *sh)

ansible-lint:
	@echo "Running 'ansible-lint' on selected yaml files"
	ansible-lint --offline ansible/roles/test/ohpc-huawei-*yml \
		ansible/roles/test/ohpc-lenovo-*yml \
		ansible/roles/common/automatic-updates.yml \
		ansible/roles/common/handlers.yml \
		ansible/roles/repos/repos-aarch64.yml \
		ansible/roles/obs/ohpc-lenovo-repo.yml

ruff-lint:
	@echo "Running 'ruff' on selected Python files"
	ruff check \
		obs/obs_config.py \
		ansible/roles/test/files/computes_installed.py
	ruff format --diff \
		obs/obs_config.py \
		ansible/roles/test/files/computes_installed.py
