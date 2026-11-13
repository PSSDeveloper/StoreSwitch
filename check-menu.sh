#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p .build/checks
/usr/bin/xcrun --sdk macosx swiftc \
    -module-cache-path .build/checks/modules -swift-version 5 -warnings-as-errors \
    -framework AppKit -framework ApplicationServices -framework Security \
    Sources/AppLanguage.swift Sources/StoreAX.swift Sources/SwitchCoordinator.swift Sources/PasswordKeychain.swift \
    Sources/AccountDrafts.swift Tests/CoordinatorChecks.swift \
    -o .build/checks/CoordinatorChecks
.build/checks/CoordinatorChecks
