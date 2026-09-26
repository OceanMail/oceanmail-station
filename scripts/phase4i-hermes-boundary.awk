# Parse actual HERMES lifecycle events, not every raw modem notification.
# Upstream explicitly acknowledges idle duplicate DISCONNECTED without rearming
# retirement. Cancel only that unmatched notification; never invent a cleanup.
$0 == "TNC: DISCONNECTED" {
    before_disconnect=latest
    disconnects++
    latest="disconnect"
    can_ignore=1
    next
}
$0 == "DISCONNECTED with no link up, ignoring." {
    if (can_ignore) {
        disconnects--
        ignored++
        latest=before_disconnect
        can_ignore=0
    } else {
        latest="invalid"
    }
    next
}
index($0, "TNC: CONNECTED ") == 1 {
    latest="connected"
    can_ignore=0
    next
}
$0 == "Connection cleanup complete." {
    cleans++
    latest="clean"
    can_ignore=0
}
END {
    if (latest == "") latest="none"
    printf "%s %d %d %d\n", latest, disconnects+0, cleans+0, ignored+0
}
