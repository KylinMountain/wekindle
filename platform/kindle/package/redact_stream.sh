#!/bin/sh
# Conservative line-oriented redaction for crash reports and diagnostics.
awk '
BEGIN { IGNORECASE = 1 }
{
    lower = tolower($0)
    if (lower ~ /(^|[^a-z])(cookie|authorization|api[_-]?key|wr_skey|wr_gid|wr_vid|wr_rt|wr_ticket|wr_wrpa|x-wrpa-[0-9]+|thirdwx|bearer|token)[=: ]/) {
        print "[REDACTED sensitive line]"
        next
    }
    if (lower ~ /weread\.qq\.com/ \
        && lower ~ /[?&](token|ticket|wr_[a-z0-9_-]+|x-wrpa-[0-9]+)=/) {
        print "[REDACTED sensitive line]"
        next
    }
    line = $0
    gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "[REDACTED-IP]", line)
    gsub(/([0-9A-Fa-f][0-9A-Fa-f]:){5}[0-9A-Fa-f][0-9A-Fa-f]/, "[REDACTED-MAC]", line)
    print line
}'
