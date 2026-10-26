# Changelog

## [0.5.0](https://github.com/jsonify/ado-desk/compare/v0.4.1...v0.5.0) (2026-10-26)


### Features

* **app:** filter reports by work item type and list closed stories in a table ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0)), closes [#29](https://github.com/jsonify/ado-desk/issues/29) [#30](https://github.com/jsonify/ado-desk/issues/30) [#31](https://github.com/jsonify/ado-desk/issues/31) [#2](https://github.com/jsonify/ado-desk/issues/2) [#3](https://github.com/jsonify/ado-desk/issues/3) [#4](https://github.com/jsonify/ado-desk/issues/4) [#5](https://github.com/jsonify/ado-desk/issues/5) [#6](https://github.com/jsonify/ado-desk/issues/6) [#7](https://github.com/jsonify/ado-desk/issues/7)
* **app:** report type filters, Closed Stories table, linked IDs, and engine bug fixes ([7cb0601](https://github.com/jsonify/ado-desk/commit/7cb0601febe3e3db09e374c51539c8ba19ad8a25))


### Bug Fixes

* **app:** show work item IDs without a thousands separator ([7bcf236](https://github.com/jsonify/ado-desk/commit/7bcf236b9f993090c883a56078e24ce508c5d4eb)), closes [#28](https://github.com/jsonify/ado-desk/issues/28)
* **engine:** 404s map to STORY_NOT_FOUND, ITERATION_NOT_FOUND or NOT_FOUND by command ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0))
* **engine:** export-closed-stories compares zero-padded dates and names the default file after them ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0))
* **engine:** export-closed-stories no longer includes items closed the day after --to-date ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0))
* **engine:** export-modifications reads every batch instead of stopping at the first revision past --to-date ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0))
* **engine:** iteration-pick reports a malformed --on as VALIDATION_ERROR ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0))
* **engine:** SSL_CERT_FILE and SSL_CERT_DIR must exist, else CONFIG_ERROR ([1c731ae](https://github.com/jsonify/ado-desk/commit/1c731ae0b8f52d0c98dd81b1f8de2d8efe1844d0))

## [0.4.1](https://github.com/jsonify/ado-desk/compare/v0.4.0...v0.4.1) (2026-10-26)


### Bug Fixes

* match report assignees by email as well as display name ([a7bb988](https://github.com/jsonify/ado-desk/commit/a7bb988d6a27c9d59fdec2bed8102bf0f4f42ace))

## [0.4.0](https://github.com/jsonify/ado-desk/compare/v0.3.2...v0.4.0) (2026-10-26)


### Features

* add a weekly report across area paths ([004f7b6](https://github.com/jsonify/ado-desk/commit/004f7b6e6dd2a70baa1dd50de0979a08260d486d))
* add a weekly report across area paths ([b585784](https://github.com/jsonify/ado-desk/commit/b585784e59892a27868afd64b3619e1d052bb184))

## [0.3.2](https://github.com/jsonify/ado-desk/compare/v0.3.1...v0.3.2) (2026-10-25)


### Bug Fixes

* **app:** cap the sidebar width ([2f9177f](https://github.com/jsonify/ado-desk/commit/2f9177f0d0d4a2476e3232a66ec1e9dd53e402d7))
* **app:** cap the sidebar width ([8159b59](https://github.com/jsonify/ado-desk/commit/8159b59555e9d11442e890842f6e7855db95c77d))

## [0.3.1](https://github.com/jsonify/ado-desk/compare/v0.3.0...v0.3.1) (2026-10-25)


### Bug Fixes

* **app:** don't read the Keychain token on the main thread at launch ([b7f2c4d](https://github.com/jsonify/ado-desk/commit/b7f2c4d336fb8af43a73f7832397693e4f722121))
* **app:** don't read the Keychain token on the main thread at launch ([6def98f](https://github.com/jsonify/ado-desk/commit/6def98f7509abc1fcaf5bf435155ba50d8a393ca))
* **scripts:** keep seeding when the team area can't be set ([f2dbac0](https://github.com/jsonify/ado-desk/commit/f2dbac0258fd96f50858289bf3cc5d265aae5ef3))
* **scripts:** keep seeding when the team area can't be set ([69005f2](https://github.com/jsonify/ado-desk/commit/69005f2b3ef95c73b532b7e72f745c6f2bcfe51d))

## [0.3.0](https://github.com/jsonify/ado-desk/compare/v0.2.1...v0.3.0) (2026-10-25)


### Features

* **app:** add the ADO Desk app icon ([de179f5](https://github.com/jsonify/ado-desk/commit/de179f5d6503ba0757e54b6353b73e58303d6bea))


### Bug Fixes

* **engine:** format inline code in Markdown list items ([7385bd4](https://github.com/jsonify/ado-desk/commit/7385bd4be2eebefd7e433b80bba2546200da9342))
* **engine:** include Resolved items in export-closed-stories ([549e475](https://github.com/jsonify/ado-desk/commit/549e4754e5acff8d2de36c1108126ca907af548d))

## [0.2.1](https://github.com/jsonify/ado-desk/compare/v0.2.0...v0.2.1) (2026-10-25)


### Bug Fixes

* **app:** point the updater and installer at the renamed jsonify/ado-desk repo ([e19a36e](https://github.com/jsonify/ado-desk/commit/e19a36ed4f6c552fe1a22fff78271ec6af41f3ab))

## [0.2.0](https://github.com/jsonify/ado-cli-tool/compare/v0.1.0...v0.2.0) (2026-10-25)


### Features

* **app:** check for and install updates from GitHub releases ([7438ef2](https://github.com/jsonify/ado-cli-tool/commit/7438ef28e775507e9cd20e70abc0e2db339c3721))
* **app:** self-updating releases, ported from Skreener ([57b3010](https://github.com/jsonify/ado-cli-tool/commit/57b3010661d51d890ac6b6ca06a520b65ede4220))
