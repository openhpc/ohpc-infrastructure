lint: codespell-lint whitespace-lint shellcheck-lint shfmt-lint ansible-lint

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
		ansible/roles/common/handlers.yml \
		ansible/roles/repos/repos-aarch64.yml
