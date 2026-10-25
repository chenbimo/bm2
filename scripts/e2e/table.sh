#!/bin/bash
# `bm2 list` 的输出解析,给 e2e 与 soak 共用。
#
# 实例表是画框线的(NAME/ID/PID/PORT/MODE/EXEC/STATUS/TIMES/MEMORY/UPTIME/CWD),
# 语言由门禁固定为 en。断言按表头名取单元格而不是按空白切词:列序或对齐变了只会
# 读错一列,不会静默读到框线。调用方负责把 bm2 放进 PATH。

# row_count <app>:该项目的实例行数。
row_count() {
  bm2 list "$1" 2>/dev/null | awk -F'│' -v app="$1" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { if (trim($2) == app) n++ } END { print n + 0 }'
}

# col_values <app> <HEADER>:每行一个该列的值。
col_values() {
  bm2 list "$1" 2>/dev/null | awk -F'│' -v app="$1" -v want="$2" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      n = 0
      for (i = 2; i < NF; i++) cell[++n] = trim($i)
      if (n == 0) next
      if (cell[1] == "NAME") {
        for (i = 1; i <= n; i++) if (toupper(cell[i]) == toupper(want)) col = i
        next
      }
      if (cell[1] == app && col) print cell[col]
    }'
}

# cell <app> <HEADER> [行号,默认 1]
cell() {
  col_values "$1" "$2" | sed -n "${3:-1}p"
}

# daemon_cell <HEADER>:守护进程摘要(pid/fds/rss/uptime/instances/commands/
# restarts/removals)对应的值。摘要表在实例表之前,取表头之后的第一个数据行。
daemon_cell() {
  bm2 list 2>/dev/null | awk -F'│' -v want="$1" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      n = 0
      for (i = 2; i < NF; i++) cell[++n] = trim($i)
      if (n == 0) next
      if (cell[1] == "pid") {
        for (i = 1; i <= n; i++) if (toupper(cell[i]) == toupper(want)) col = i
        next
      }
      if (col && !printed) { print cell[col]; printed = 1 }
    }'
}
