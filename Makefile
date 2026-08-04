# Convenience targets — Mac app lives in apps/mac
.PHONY: build bundle run clean icons

build bundle run clean icons:
	$(MAKE) -C apps/mac $@
