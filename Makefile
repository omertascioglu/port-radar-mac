# Convenience targets — Mac app lives in apps/mac
.PHONY: build bundle run clean icons dmg publish notarize release verify identities

build bundle run clean icons dmg publish notarize release verify identities:
	$(MAKE) -C apps/mac $@
