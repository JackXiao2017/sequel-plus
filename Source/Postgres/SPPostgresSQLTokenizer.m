#import "SPPostgresSQLTokenizer.h"

@interface SPPostgresSQLToken ()
- (instancetype)initWithKind:(SPPostgresTokenKind)kind range:(NSRange)range;
@end

@implementation SPPostgresSQLToken

- (instancetype)initWithKind:(SPPostgresTokenKind)kind range:(NSRange)range
{
	if ((self = [super init])) {
		_kind = kind;
		_range = range;
	}
	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<token %lu %@>", (unsigned long)_kind, NSStringFromRange(_range)];
}

@end

// Frozen from the PostgreSQL 18 test server (Scripts/pg-test-servers.sh up). Regenerate by re-running the queries.

// SELECT word FROM pg_get_keywords(): 494 rows
static const char *const SPPostgresKeywordWords[] = {
	"abort", "absent", "absolute", "access", "action", "add", "admin", "after",
	"aggregate", "all", "also", "alter", "always", "analyse", "analyze", "and",
	"any", "array", "as", "asc", "asensitive", "assertion", "assignment", "asymmetric",
	"at", "atomic", "attach", "attribute", "authorization", "backward", "before", "begin",
	"between", "bigint", "binary", "bit", "boolean", "both", "breadth", "by",
	"cache", "call", "called", "cascade", "cascaded", "case", "cast", "catalog",
	"chain", "char", "character", "characteristics", "check", "checkpoint", "class", "close",
	"cluster", "coalesce", "collate", "collation", "column", "columns", "comment", "comments",
	"commit", "committed", "compression", "concurrently", "conditional", "configuration", "conflict", "connection",
	"constraint", "constraints", "content", "continue", "conversion", "copy", "cost", "create",
	"cross", "csv", "cube", "current", "current_catalog", "current_date", "current_role", "current_schema",
	"current_time", "current_timestamp", "current_user", "cursor", "cycle", "data", "database", "day",
	"deallocate", "dec", "decimal", "declare", "default", "defaults", "deferrable", "deferred",
	"definer", "delete", "delimiter", "delimiters", "depends", "depth", "desc", "detach",
	"dictionary", "disable", "discard", "distinct", "do", "document", "domain", "double",
	"drop", "each", "else", "empty", "enable", "encoding", "encrypted", "end",
	"enforced", "enum", "error", "escape", "event", "except", "exclude", "excluding",
	"exclusive", "execute", "exists", "explain", "expression", "extension", "external", "extract",
	"false", "family", "fetch", "filter", "finalize", "first", "float", "following",
	"for", "force", "foreign", "format", "forward", "freeze", "from", "full",
	"function", "functions", "generated", "global", "grant", "granted", "greatest", "group",
	"grouping", "groups", "handler", "having", "header", "hold", "hour", "identity",
	"if", "ilike", "immediate", "immutable", "implicit", "import", "in", "include",
	"including", "increment", "indent", "index", "indexes", "inherit", "inherits", "initially",
	"inline", "inner", "inout", "input", "insensitive", "insert", "instead", "int",
	"integer", "intersect", "interval", "into", "invoker", "is", "isnull", "isolation",
	"join", "json", "json_array", "json_arrayagg", "json_exists", "json_object", "json_objectagg", "json_query",
	"json_scalar", "json_serialize", "json_table", "json_value", "keep", "key", "keys", "label",
	"language", "large", "last", "lateral", "leading", "leakproof", "least", "left",
	"level", "like", "limit", "listen", "load", "local", "localtime", "localtimestamp",
	"location", "lock", "locked", "logged", "mapping", "match", "matched", "materialized",
	"maxvalue", "merge", "merge_action", "method", "minute", "minvalue", "mode", "month",
	"move", "name", "names", "national", "natural", "nchar", "nested", "new",
	"next", "nfc", "nfd", "nfkc", "nfkd", "no", "none", "normalize",
	"normalized", "not", "nothing", "notify", "notnull", "nowait", "null", "nullif",
	"nulls", "numeric", "object", "objects", "of", "off", "offset", "oids",
	"old", "omit", "on", "only", "operator", "option", "options", "or",
	"order", "ordinality", "others", "out", "outer", "over", "overlaps", "overlay",
	"overriding", "owned", "owner", "parallel", "parameter", "parser", "partial", "partition",
	"passing", "password", "path", "period", "placing", "plan", "plans", "policy",
	"position", "preceding", "precision", "prepare", "prepared", "preserve", "primary", "prior",
	"privileges", "procedural", "procedure", "procedures", "program", "publication", "quote", "quotes",
	"range", "read", "real", "reassign", "recursive", "ref", "references", "referencing",
	"refresh", "reindex", "relative", "release", "rename", "repeatable", "replace", "replica",
	"reset", "restart", "restrict", "return", "returning", "returns", "revoke", "right",
	"role", "rollback", "rollup", "routine", "routines", "row", "rows", "rule",
	"savepoint", "scalar", "schema", "schemas", "scroll", "search", "second", "security",
	"select", "sequence", "sequences", "serializable", "server", "session", "session_user", "set",
	"setof", "sets", "share", "show", "similar", "simple", "skip", "smallint",
	"snapshot", "some", "source", "sql", "stable", "standalone", "start", "statement",
	"statistics", "stdin", "stdout", "storage", "stored", "strict", "string", "strip",
	"subscription", "substring", "support", "symmetric", "sysid", "system", "system_user", "table",
	"tables", "tablesample", "tablespace", "target", "temp", "template", "temporary", "text",
	"then", "ties", "time", "timestamp", "to", "trailing", "transaction", "transform",
	"treat", "trigger", "trim", "true", "truncate", "trusted", "type", "types",
	"uescape", "unbounded", "uncommitted", "unconditional", "unencrypted", "union", "unique", "unknown",
	"unlisten", "unlogged", "until", "update", "user", "using", "vacuum", "valid",
	"validate", "validator", "value", "values", "varchar", "variadic", "varying", "verbose",
	"version", "view", "views", "virtual", "volatile", "when", "where", "whitespace",
	"window", "with", "within", "without", "work", "wrapper", "write", "xml",
	"xmlattributes", "xmlconcat", "xmlelement", "xmlexists", "xmlforest", "xmlnamespaces", "xmlparse", "xmlpi",
	"xmlroot", "xmlserialize", "xmltable", "year", "yes", "zone",
};

// SELECT typname FROM pg_type WHERE typnamespace = 'pg_catalog'::regnamespace AND typtype IN ('b','p','r','m')
// AND typname !~ '^_': 107 rows
static const char *const SPPostgresTypeNames[] = {
	"aclitem", "any", "anyarray", "anycompatible", "anycompatiblearray", "anycompatiblemultirange", "anycompatiblenonarray", "anycompatiblerange",
	"anyelement", "anyenum", "anymultirange", "anynonarray", "anyrange", "bit", "bool", "box",
	"bpchar", "bytea", "char", "cid", "cidr", "circle", "cstring", "date",
	"datemultirange", "daterange", "event_trigger", "fdw_handler", "float4", "float8", "gtsvector", "index_am_handler",
	"inet", "int2", "int2vector", "int4", "int4multirange", "int4range", "int8", "int8multirange",
	"int8range", "internal", "interval", "json", "jsonb", "jsonpath", "language_handler", "line",
	"lseg", "macaddr", "macaddr8", "money", "name", "numeric", "nummultirange", "numrange",
	"oid", "oidvector", "path", "pg_brin_bloom_summary", "pg_brin_minmax_multi_summary", "pg_ddl_command", "pg_dependencies", "pg_lsn",
	"pg_mcv_list", "pg_ndistinct", "pg_node_tree", "pg_snapshot", "point", "polygon", "record", "refcursor",
	"regclass", "regcollation", "regconfig", "regdictionary", "regnamespace", "regoper", "regoperator", "regproc",
	"regprocedure", "regrole", "regtype", "table_am_handler", "text", "tid", "time", "timestamp",
	"timestamptz", "timetz", "trigger", "tsm_handler", "tsmultirange", "tsquery", "tsrange", "tstzmultirange",
	"tstzrange", "tsvector", "txid_snapshot", "unknown", "uuid", "varbit", "varchar", "void",
	"xid", "xid8", "xml",
};

// SELECT DISTINCT proname FROM pg_proc WHERE pronamespace = 'pg_catalog'::regnamespace AND proname !~ '^_'
// AND proname !~ '^pg_': 2382 rows (lowercased, so names differing only in case merge), plus the six pg_*
// functions pg_sleep, pg_size_pretty, pg_typeof, pg_get_viewdef, pg_cancel_backend, pg_terminate_backend
// = 2388 names
static const char *const SPPostgresFunctionNameWords[] = {
	"abbrev", "abs", "aclcontains", "acldefault", "aclexplode", "aclinsert", "aclitemeq", "aclitemin",
	"aclitemout", "aclremove", "acos", "acosd", "acosh", "age", "amvalidate", "any_in",
	"any_out", "any_value", "any_value_transfn", "anyarray_in", "anyarray_out", "anyarray_recv", "anyarray_send", "anycompatible_in",
	"anycompatible_out", "anycompatiblearray_in", "anycompatiblearray_out", "anycompatiblearray_recv", "anycompatiblearray_send", "anycompatiblemultirange_in", "anycompatiblemultirange_out", "anycompatiblenonarray_in",
	"anycompatiblenonarray_out", "anycompatiblerange_in", "anycompatiblerange_out", "anyelement_in", "anyelement_out", "anyenum_in", "anyenum_out", "anymultirange_in",
	"anymultirange_out", "anynonarray_in", "anynonarray_out", "anyrange_in", "anyrange_out", "anytextcat", "area", "areajoinsel",
	"areasel", "array_agg", "array_agg_array_combine", "array_agg_array_deserialize", "array_agg_array_finalfn", "array_agg_array_serialize", "array_agg_array_transfn", "array_agg_combine",
	"array_agg_deserialize", "array_agg_finalfn", "array_agg_serialize", "array_agg_transfn", "array_append", "array_append_support", "array_cat", "array_dims",
	"array_eq", "array_fill", "array_ge", "array_gt", "array_in", "array_larger", "array_le", "array_length",
	"array_lower", "array_lt", "array_ndims", "array_ne", "array_out", "array_position", "array_positions", "array_prepend",
	"array_prepend_support", "array_recv", "array_remove", "array_replace", "array_reverse", "array_sample", "array_send", "array_shuffle",
	"array_smaller", "array_sort", "array_subscript_handler", "array_subscript_handler_support", "array_to_json", "array_to_string", "array_to_tsvector", "array_typanalyze",
	"array_unnest_support", "array_upper", "arraycontained", "arraycontains", "arraycontjoinsel", "arraycontsel", "arrayoverlap", "ascii",
	"asin", "asind", "asinh", "atan", "atan2", "atan2d", "atand", "atanh",
	"avg", "bernoulli", "big5_to_euc_tw", "big5_to_mic", "big5_to_utf8", "binary_upgrade_add_sub_rel_state", "binary_upgrade_create_empty_extension", "binary_upgrade_logical_slot_has_caught_up",
	"binary_upgrade_replorigin_advance", "binary_upgrade_set_missing_value", "binary_upgrade_set_next_array_pg_type_oid", "binary_upgrade_set_next_heap_pg_class_oid", "binary_upgrade_set_next_heap_relfilenode", "binary_upgrade_set_next_index_pg_class_oid", "binary_upgrade_set_next_index_relfilenode", "binary_upgrade_set_next_multirange_array_pg_type_oid",
	"binary_upgrade_set_next_multirange_pg_type_oid", "binary_upgrade_set_next_pg_authid_oid", "binary_upgrade_set_next_pg_enum_oid", "binary_upgrade_set_next_pg_tablespace_oid", "binary_upgrade_set_next_pg_type_oid", "binary_upgrade_set_next_toast_pg_class_oid", "binary_upgrade_set_next_toast_relfilenode", "binary_upgrade_set_record_init_privs",
	"bit", "bit_and", "bit_count", "bit_in", "bit_length", "bit_or", "bit_out", "bit_recv",
	"bit_send", "bit_xor", "bitand", "bitcat", "bitcmp", "biteq", "bitge", "bitgt",
	"bitle", "bitlt", "bitne", "bitnot", "bitor", "bitshiftleft", "bitshiftright", "bittypmodin",
	"bittypmodout", "bitxor", "bool", "bool_accum", "bool_accum_inv", "bool_alltrue", "bool_and", "bool_anytrue",
	"bool_or", "booland_statefunc", "booleq", "boolge", "boolgt", "boolin", "boolle", "boollt",
	"boolne", "boolor_statefunc", "boolout", "boolrecv", "boolsend", "bound_box", "box", "box_above",
	"box_above_eq", "box_add", "box_below", "box_below_eq", "box_center", "box_contain", "box_contain_pt", "box_contained",
	"box_distance", "box_div", "box_eq", "box_ge", "box_gt", "box_in", "box_intersect", "box_le",
	"box_left", "box_lt", "box_mul", "box_out", "box_overabove", "box_overbelow", "box_overlap", "box_overleft",
	"box_overright", "box_recv", "box_right", "box_same", "box_send", "box_sub", "bpchar", "bpchar_larger",
	"bpchar_pattern_ge", "bpchar_pattern_gt", "bpchar_pattern_le", "bpchar_pattern_lt", "bpchar_smaller", "bpchar_sortsupport", "bpcharcmp", "bpchareq",
	"bpcharge", "bpchargt", "bpchariclike", "bpcharicnlike", "bpcharicregexeq", "bpcharicregexne", "bpcharin", "bpcharle",
	"bpcharlike", "bpcharlt", "bpcharne", "bpcharnlike", "bpcharout", "bpcharrecv", "bpcharregexeq", "bpcharregexne",
	"bpcharsend", "bpchartypmodin", "bpchartypmodout", "brin_bloom_add_value", "brin_bloom_consistent", "brin_bloom_opcinfo", "brin_bloom_options", "brin_bloom_summary_in",
	"brin_bloom_summary_out", "brin_bloom_summary_recv", "brin_bloom_summary_send", "brin_bloom_union", "brin_desummarize_range", "brin_inclusion_add_value", "brin_inclusion_consistent", "brin_inclusion_opcinfo",
	"brin_inclusion_union", "brin_minmax_add_value", "brin_minmax_consistent", "brin_minmax_multi_add_value", "brin_minmax_multi_consistent", "brin_minmax_multi_distance_date", "brin_minmax_multi_distance_float4", "brin_minmax_multi_distance_float8",
	"brin_minmax_multi_distance_inet", "brin_minmax_multi_distance_int2", "brin_minmax_multi_distance_int4", "brin_minmax_multi_distance_int8", "brin_minmax_multi_distance_interval", "brin_minmax_multi_distance_macaddr", "brin_minmax_multi_distance_macaddr8", "brin_minmax_multi_distance_numeric",
	"brin_minmax_multi_distance_pg_lsn", "brin_minmax_multi_distance_tid", "brin_minmax_multi_distance_time", "brin_minmax_multi_distance_timestamp", "brin_minmax_multi_distance_timetz", "brin_minmax_multi_distance_uuid", "brin_minmax_multi_opcinfo", "brin_minmax_multi_options",
	"brin_minmax_multi_summary_in", "brin_minmax_multi_summary_out", "brin_minmax_multi_summary_recv", "brin_minmax_multi_summary_send", "brin_minmax_multi_union", "brin_minmax_opcinfo", "brin_minmax_union", "brin_summarize_new_values",
	"brin_summarize_range", "brinhandler", "broadcast", "btarraycmp", "btboolcmp", "btboolskipsupport", "btbpchar_pattern_cmp", "btbpchar_pattern_sortsupport",
	"btcharcmp", "btcharskipsupport", "btequalimage", "btfloat48cmp", "btfloat4cmp", "btfloat4sortsupport", "btfloat84cmp", "btfloat8cmp",
	"btfloat8sortsupport", "bthandler", "btint24cmp", "btint28cmp", "btint2cmp", "btint2skipsupport", "btint2sortsupport", "btint42cmp",
	"btint48cmp", "btint4cmp", "btint4skipsupport", "btint4sortsupport", "btint82cmp", "btint84cmp", "btint8cmp", "btint8skipsupport",
	"btint8sortsupport", "btnamecmp", "btnamesortsupport", "btnametextcmp", "btoidcmp", "btoidskipsupport", "btoidsortsupport", "btoidvectorcmp",
	"btrecordcmp", "btrecordimagecmp", "btrim", "bttext_pattern_cmp", "bttext_pattern_sortsupport", "bttextcmp", "bttextnamecmp", "bttextsortsupport",
	"bttidcmp", "btvarstrequalimage", "bytea", "bytea_larger", "bytea_smaller", "bytea_sortsupport", "bytea_string_agg_finalfn", "bytea_string_agg_transfn",
	"byteacat", "byteacmp", "byteaeq", "byteage", "byteagt", "byteain", "byteale", "bytealike",
	"bytealt", "byteane", "byteanlike", "byteaout", "bytearecv", "byteasend", "cardinality", "casefold",
	"cash_cmp", "cash_div_cash", "cash_div_flt4", "cash_div_flt8", "cash_div_int2", "cash_div_int4", "cash_div_int8", "cash_eq",
	"cash_ge", "cash_gt", "cash_in", "cash_le", "cash_lt", "cash_mi", "cash_mul_flt4", "cash_mul_flt8",
	"cash_mul_int2", "cash_mul_int4", "cash_mul_int8", "cash_ne", "cash_out", "cash_pl", "cash_recv", "cash_send",
	"cash_words", "cashlarger", "cashsmaller", "cbrt", "ceil", "ceiling", "center", "char",
	"char_length", "character_length", "chareq", "charge", "chargt", "charin", "charle", "charlt",
	"charne", "charout", "charrecv", "charsend", "chr", "cideq", "cidin", "cidout",
	"cidr", "cidr_in", "cidr_out", "cidr_recv", "cidr_send", "cidrecv", "cidsend", "circle",
	"circle_above", "circle_add_pt", "circle_below", "circle_center", "circle_contain", "circle_contain_pt", "circle_contained", "circle_distance",
	"circle_div_pt", "circle_eq", "circle_ge", "circle_gt", "circle_in", "circle_le", "circle_left", "circle_lt",
	"circle_mul_pt", "circle_ne", "circle_out", "circle_overabove", "circle_overbelow", "circle_overlap", "circle_overleft", "circle_overright",
	"circle_recv", "circle_right", "circle_same", "circle_send", "circle_sub_pt", "clock_timestamp", "close_ls", "close_lseg",
	"close_pb", "close_pl", "close_ps", "close_sb", "col_description", "concat", "concat_ws", "contjoinsel",
	"contsel", "convert", "convert_from", "convert_to", "corr", "cos", "cosd", "cosh",
	"cot", "cotd", "count", "covar_pop", "covar_samp", "crc32", "crc32c", "cstring_in",
	"cstring_out", "cstring_recv", "cstring_send", "cume_dist", "cume_dist_final", "current_database", "current_query", "current_schema",
	"current_schemas", "current_setting", "current_user", "currtid2", "currval", "cursor_to_xml", "cursor_to_xmlschema", "database_to_xml",
	"database_to_xml_and_xmlschema", "database_to_xmlschema", "date", "date_add", "date_bin", "date_cmp", "date_cmp_timestamp", "date_cmp_timestamptz",
	"date_eq", "date_eq_timestamp", "date_eq_timestamptz", "date_ge", "date_ge_timestamp", "date_ge_timestamptz", "date_gt", "date_gt_timestamp",
	"date_gt_timestamptz", "date_in", "date_larger", "date_le", "date_le_timestamp", "date_le_timestamptz", "date_lt", "date_lt_timestamp",
	"date_lt_timestamptz", "date_mi", "date_mi_interval", "date_mii", "date_ne", "date_ne_timestamp", "date_ne_timestamptz", "date_out",
	"date_part", "date_pl_interval", "date_pli", "date_recv", "date_send", "date_skipsupport", "date_smaller", "date_sortsupport",
	"date_subtract", "date_trunc", "datemultirange", "daterange", "daterange_canonical", "daterange_subdiff", "datetime_pl", "datetimetz_pl",
	"dcbrt", "decode", "degrees", "dense_rank", "dense_rank_final", "dexp", "diagonal", "diameter",
	"dispell_init", "dispell_lexize", "dist_bp", "dist_bs", "dist_cpoint", "dist_cpoly", "dist_lp", "dist_ls",
	"dist_pathp", "dist_pb", "dist_pc", "dist_pl", "dist_polyc", "dist_polyp", "dist_ppath", "dist_ppoly",
	"dist_ps", "dist_sb", "dist_sl", "dist_sp", "div", "dlog1", "dlog10", "domain_in",
	"domain_recv", "dpow", "dround", "dsimple_init", "dsimple_lexize", "dsnowball_init", "dsnowball_lexize", "dsqrt",
	"dsynonym_init", "dsynonym_lexize", "dtrunc", "elem_contained_by_multirange", "elem_contained_by_range", "elem_contained_by_range_support", "encode", "enum_cmp",
	"enum_eq", "enum_first", "enum_ge", "enum_gt", "enum_in", "enum_larger", "enum_last", "enum_le",
	"enum_lt", "enum_ne", "enum_out", "enum_range", "enum_recv", "enum_send", "enum_smaller", "eqjoinsel",
	"eqsel", "erf", "erfc", "euc_cn_to_mic", "euc_cn_to_utf8", "euc_jis_2004_to_shift_jis_2004", "euc_jis_2004_to_utf8", "euc_jp_to_mic",
	"euc_jp_to_sjis", "euc_jp_to_utf8", "euc_kr_to_mic", "euc_kr_to_utf8", "euc_tw_to_big5", "euc_tw_to_mic", "euc_tw_to_utf8", "event_trigger_in",
	"event_trigger_out", "every", "exp", "extract", "factorial", "family", "fdw_handler_in", "fdw_handler_out",
	"first_value", "float4", "float48div", "float48eq", "float48ge", "float48gt", "float48le", "float48lt",
	"float48mi", "float48mul", "float48ne", "float48pl", "float4_accum", "float4abs", "float4div", "float4eq",
	"float4ge", "float4gt", "float4in", "float4larger", "float4le", "float4lt", "float4mi", "float4mul",
	"float4ne", "float4out", "float4pl", "float4recv", "float4send", "float4smaller", "float4um", "float4up",
	"float8", "float84div", "float84eq", "float84ge", "float84gt", "float84le", "float84lt", "float84mi",
	"float84mul", "float84ne", "float84pl", "float8_accum", "float8_avg", "float8_combine", "float8_corr", "float8_covar_pop",
	"float8_covar_samp", "float8_regr_accum", "float8_regr_avgx", "float8_regr_avgy", "float8_regr_combine", "float8_regr_intercept", "float8_regr_r2", "float8_regr_slope",
	"float8_regr_sxx", "float8_regr_sxy", "float8_regr_syy", "float8_stddev_pop", "float8_stddev_samp", "float8_var_pop", "float8_var_samp", "float8abs",
	"float8div", "float8eq", "float8ge", "float8gt", "float8in", "float8larger", "float8le", "float8lt",
	"float8mi", "float8mul", "float8ne", "float8out", "float8pl", "float8recv", "float8send", "float8smaller",
	"float8um", "float8up", "floor", "flt4_mul_cash", "flt8_mul_cash", "fmgr_c_validator", "fmgr_internal_validator", "fmgr_sql_validator",
	"format", "format_type", "gamma", "gb18030_to_utf8", "gbk_to_utf8", "gcd", "gen_random_uuid", "generate_series",
	"generate_series_int4_support", "generate_series_int8_support", "generate_series_numeric_support", "generate_series_timestamp_support", "generate_subscripts", "get_bit", "get_byte", "get_current_ts_config",
	"getdatabaseencoding", "getpgusername", "gin_clean_pending_list", "gin_cmp_prefix", "gin_cmp_tslexeme", "gin_compare_jsonb", "gin_consistent_jsonb", "gin_consistent_jsonb_path",
	"gin_extract_jsonb", "gin_extract_jsonb_path", "gin_extract_jsonb_query", "gin_extract_jsonb_query_path", "gin_extract_tsquery", "gin_extract_tsvector", "gin_triconsistent_jsonb", "gin_triconsistent_jsonb_path",
	"gin_tsquery_consistent", "gin_tsquery_triconsistent", "ginarrayconsistent", "ginarrayextract", "ginarraytriconsistent", "ginhandler", "ginqueryarrayextract", "gist_box_consistent",
	"gist_box_distance", "gist_box_penalty", "gist_box_picksplit", "gist_box_same", "gist_box_union", "gist_circle_compress", "gist_circle_consistent", "gist_circle_distance",
	"gist_point_compress", "gist_point_consistent", "gist_point_distance", "gist_point_fetch", "gist_point_sortsupport", "gist_poly_compress", "gist_poly_consistent", "gist_poly_distance",
	"gist_translate_cmptype_common", "gisthandler", "gtsquery_compress", "gtsquery_consistent", "gtsquery_penalty", "gtsquery_picksplit", "gtsquery_same", "gtsquery_union",
	"gtsvector_compress", "gtsvector_consistent", "gtsvector_decompress", "gtsvector_options", "gtsvector_penalty", "gtsvector_picksplit", "gtsvector_same", "gtsvector_union",
	"gtsvectorin", "gtsvectorout", "has_any_column_privilege", "has_column_privilege", "has_database_privilege", "has_foreign_data_wrapper_privilege", "has_function_privilege", "has_language_privilege",
	"has_largeobject_privilege", "has_parameter_privilege", "has_schema_privilege", "has_sequence_privilege", "has_server_privilege", "has_table_privilege", "has_tablespace_privilege", "has_type_privilege",
	"hash_aclitem", "hash_aclitem_extended", "hash_array", "hash_array_extended", "hash_multirange", "hash_multirange_extended", "hash_numeric", "hash_numeric_extended",
	"hash_range", "hash_range_extended", "hash_record", "hash_record_extended", "hashbool", "hashboolextended", "hashbpchar", "hashbpcharextended",
	"hashbytea", "hashbyteaextended", "hashchar", "hashcharextended", "hashcid", "hashcidextended", "hashdate", "hashdateextended",
	"hashenum", "hashenumextended", "hashfloat4", "hashfloat4extended", "hashfloat8", "hashfloat8extended", "hashhandler", "hashinet",
	"hashinetextended", "hashint2", "hashint2extended", "hashint4", "hashint4extended", "hashint8", "hashint8extended", "hashmacaddr",
	"hashmacaddr8", "hashmacaddr8extended", "hashmacaddrextended", "hashname", "hashnameextended", "hashoid", "hashoidextended", "hashoidvector",
	"hashoidvectorextended", "hashtext", "hashtextextended", "hashtid", "hashtidextended", "hashvarlena", "hashvarlenaextended", "hashxid",
	"hashxid8", "hashxid8extended", "hashxidextended", "heap_tableam_handler", "height", "host", "hostmask", "iclikejoinsel",
	"iclikesel", "icnlikejoinsel", "icnlikesel", "icregexeqjoinsel", "icregexeqsel", "icregexnejoinsel", "icregexnesel", "icu_unicode_version",
	"in_range", "index_am_handler_in", "index_am_handler_out", "inet_client_addr", "inet_client_port", "inet_gist_compress", "inet_gist_consistent", "inet_gist_fetch",
	"inet_gist_penalty", "inet_gist_picksplit", "inet_gist_same", "inet_gist_union", "inet_in", "inet_merge", "inet_out", "inet_recv",
	"inet_same_family", "inet_send", "inet_server_addr", "inet_server_port", "inet_spg_choose", "inet_spg_config", "inet_spg_inner_consistent", "inet_spg_leaf_consistent",
	"inet_spg_picksplit", "inetand", "inetmi", "inetmi_int8", "inetnot", "inetor", "inetpl", "initcap",
	"int2", "int24div", "int24eq", "int24ge", "int24gt", "int24le", "int24lt", "int24mi",
	"int24mul", "int24ne", "int24pl", "int28div", "int28eq", "int28ge", "int28gt", "int28le",
	"int28lt", "int28mi", "int28mul", "int28ne", "int28pl", "int2_accum", "int2_accum_inv", "int2_avg_accum",
	"int2_avg_accum_inv", "int2_mul_cash", "int2_sum", "int2abs", "int2and", "int2div", "int2eq", "int2ge",
	"int2gt", "int2in", "int2int4_sum", "int2larger", "int2le", "int2lt", "int2mi", "int2mod",
	"int2mul", "int2ne", "int2not", "int2or", "int2out", "int2pl", "int2recv", "int2send",
	"int2shl", "int2shr", "int2smaller", "int2um", "int2up", "int2vectorin", "int2vectorout", "int2vectorrecv",
	"int2vectorsend", "int2xor", "int4", "int42div", "int42eq", "int42ge", "int42gt", "int42le",
	"int42lt", "int42mi", "int42mul", "int42ne", "int42pl", "int48div", "int48eq", "int48ge",
	"int48gt", "int48le", "int48lt", "int48mi", "int48mul", "int48ne", "int48pl", "int4_accum",
	"int4_accum_inv", "int4_avg_accum", "int4_avg_accum_inv", "int4_avg_combine", "int4_mul_cash", "int4_sum", "int4abs", "int4and",
	"int4div", "int4eq", "int4ge", "int4gt", "int4in", "int4inc", "int4larger", "int4le",
	"int4lt", "int4mi", "int4mod", "int4mul", "int4multirange", "int4ne", "int4not", "int4or",
	"int4out", "int4pl", "int4range", "int4range_canonical", "int4range_subdiff", "int4recv", "int4send", "int4shl",
	"int4shr", "int4smaller", "int4um", "int4up", "int4xor", "int8", "int82div", "int82eq",
	"int82ge", "int82gt", "int82le", "int82lt", "int82mi", "int82mul", "int82ne", "int82pl",
	"int84div", "int84eq", "int84ge", "int84gt", "int84le", "int84lt", "int84mi", "int84mul",
	"int84ne", "int84pl", "int8_accum", "int8_accum_inv", "int8_avg", "int8_avg_accum", "int8_avg_accum_inv", "int8_avg_combine",
	"int8_avg_deserialize", "int8_avg_serialize", "int8_mul_cash", "int8_sum", "int8abs", "int8and", "int8dec", "int8dec_any",
	"int8div", "int8eq", "int8ge", "int8gt", "int8in", "int8inc", "int8inc_any", "int8inc_float8_float8",
	"int8inc_support", "int8larger", "int8le", "int8lt", "int8mi", "int8mod", "int8mul", "int8multirange",
	"int8ne", "int8not", "int8or", "int8out", "int8pl", "int8pl_inet", "int8range", "int8range_canonical",
	"int8range_subdiff", "int8recv", "int8send", "int8shl", "int8shr", "int8smaller", "int8um", "int8up",
	"int8xor", "integer_pl_date", "inter_lb", "inter_sb", "inter_sl", "internal_in", "internal_out", "interval",
	"interval_avg", "interval_avg_accum", "interval_avg_accum_inv", "interval_avg_combine", "interval_avg_deserialize", "interval_avg_serialize", "interval_cmp", "interval_div",
	"interval_eq", "interval_ge", "interval_gt", "interval_hash", "interval_hash_extended", "interval_in", "interval_larger", "interval_le",
	"interval_lt", "interval_mi", "interval_mul", "interval_ne", "interval_out", "interval_pl", "interval_pl_date", "interval_pl_time",
	"interval_pl_timestamp", "interval_pl_timestamptz", "interval_pl_timetz", "interval_recv", "interval_send", "interval_smaller", "interval_sum", "interval_support",
	"interval_um", "intervaltypmodin", "intervaltypmodout", "is_normalized", "isclosed", "isempty", "isfinite", "ishorizontal",
	"iso8859_1_to_utf8", "iso8859_to_utf8", "iso_to_koi8r", "iso_to_mic", "iso_to_win1251", "iso_to_win866", "isopen", "isparallel",
	"isperp", "isvertical", "johab_to_utf8", "json_agg", "json_agg_finalfn", "json_agg_strict", "json_agg_strict_transfn", "json_agg_transfn",
	"json_array_element", "json_array_element_text", "json_array_elements", "json_array_elements_text", "json_array_length", "json_build_array", "json_build_object", "json_each",
	"json_each_text", "json_extract_path", "json_extract_path_text", "json_in", "json_object", "json_object_agg", "json_object_agg_finalfn", "json_object_agg_strict",
	"json_object_agg_strict_transfn", "json_object_agg_transfn", "json_object_agg_unique", "json_object_agg_unique_strict", "json_object_agg_unique_strict_transfn", "json_object_agg_unique_transfn", "json_object_field", "json_object_field_text",
	"json_object_keys", "json_out", "json_populate_record", "json_populate_recordset", "json_recv", "json_send", "json_strip_nulls", "json_to_record",
	"json_to_recordset", "json_to_tsvector", "json_typeof", "jsonb_agg", "jsonb_agg_finalfn", "jsonb_agg_strict", "jsonb_agg_strict_transfn", "jsonb_agg_transfn",
	"jsonb_array_element", "jsonb_array_element_text", "jsonb_array_elements", "jsonb_array_elements_text", "jsonb_array_length", "jsonb_build_array", "jsonb_build_object", "jsonb_cmp",
	"jsonb_concat", "jsonb_contained", "jsonb_contains", "jsonb_delete", "jsonb_delete_path", "jsonb_each", "jsonb_each_text", "jsonb_eq",
	"jsonb_exists", "jsonb_exists_all", "jsonb_exists_any", "jsonb_extract_path", "jsonb_extract_path_text", "jsonb_ge", "jsonb_gt", "jsonb_hash",
	"jsonb_hash_extended", "jsonb_in", "jsonb_insert", "jsonb_le", "jsonb_lt", "jsonb_ne", "jsonb_object", "jsonb_object_agg",
	"jsonb_object_agg_finalfn", "jsonb_object_agg_strict", "jsonb_object_agg_strict_transfn", "jsonb_object_agg_transfn", "jsonb_object_agg_unique", "jsonb_object_agg_unique_strict", "jsonb_object_agg_unique_strict_transfn", "jsonb_object_agg_unique_transfn",
	"jsonb_object_field", "jsonb_object_field_text", "jsonb_object_keys", "jsonb_out", "jsonb_path_exists", "jsonb_path_exists_opr", "jsonb_path_exists_tz", "jsonb_path_match",
	"jsonb_path_match_opr", "jsonb_path_match_tz", "jsonb_path_query", "jsonb_path_query_array", "jsonb_path_query_array_tz", "jsonb_path_query_first", "jsonb_path_query_first_tz", "jsonb_path_query_tz",
	"jsonb_populate_record", "jsonb_populate_record_valid", "jsonb_populate_recordset", "jsonb_pretty", "jsonb_recv", "jsonb_send", "jsonb_set", "jsonb_set_lax",
	"jsonb_strip_nulls", "jsonb_subscript_handler", "jsonb_to_record", "jsonb_to_recordset", "jsonb_to_tsvector", "jsonb_typeof", "jsonpath_in", "jsonpath_out",
	"jsonpath_recv", "jsonpath_send", "justify_days", "justify_hours", "justify_interval", "koi8r_to_iso", "koi8r_to_mic", "koi8r_to_utf8",
	"koi8r_to_win1251", "koi8r_to_win866", "koi8u_to_utf8", "lag", "language_handler_in", "language_handler_out", "last_value", "lastval",
	"latin1_to_mic", "latin2_to_mic", "latin2_to_win1250", "latin3_to_mic", "latin4_to_mic", "lcm", "lead", "left",
	"length", "lgamma", "like", "like_escape", "likejoinsel", "likesel", "line", "line_distance",
	"line_eq", "line_horizontal", "line_in", "line_interpt", "line_intersect", "line_out", "line_parallel", "line_perp",
	"line_recv", "line_send", "line_vertical", "ln", "lo_close", "lo_creat", "lo_create", "lo_export",
	"lo_from_bytea", "lo_get", "lo_import", "lo_lseek", "lo_lseek64", "lo_open", "lo_put", "lo_tell",
	"lo_tell64", "lo_truncate", "lo_truncate64", "lo_unlink", "log", "log10", "loread", "lower",
	"lower_inc", "lower_inf", "lowrite", "lpad", "lseg", "lseg_center", "lseg_distance", "lseg_eq",
	"lseg_ge", "lseg_gt", "lseg_horizontal", "lseg_in", "lseg_interpt", "lseg_intersect", "lseg_le", "lseg_length",
	"lseg_lt", "lseg_ne", "lseg_out", "lseg_parallel", "lseg_perp", "lseg_recv", "lseg_send", "lseg_vertical",
	"ltrim", "macaddr", "macaddr8", "macaddr8_and", "macaddr8_cmp", "macaddr8_eq", "macaddr8_ge", "macaddr8_gt",
	"macaddr8_in", "macaddr8_le", "macaddr8_lt", "macaddr8_ne", "macaddr8_not", "macaddr8_or", "macaddr8_out", "macaddr8_recv",
	"macaddr8_send", "macaddr8_set7bit", "macaddr_and", "macaddr_cmp", "macaddr_eq", "macaddr_ge", "macaddr_gt", "macaddr_in",
	"macaddr_le", "macaddr_lt", "macaddr_ne", "macaddr_not", "macaddr_or", "macaddr_out", "macaddr_recv", "macaddr_send",
	"macaddr_sortsupport", "make_date", "make_interval", "make_time", "make_timestamp", "make_timestamptz", "makeaclitem", "masklen",
	"matchingjoinsel", "matchingsel", "max", "md5", "mic_to_big5", "mic_to_euc_cn", "mic_to_euc_jp", "mic_to_euc_kr",
	"mic_to_euc_tw", "mic_to_iso", "mic_to_koi8r", "mic_to_latin1", "mic_to_latin2", "mic_to_latin3", "mic_to_latin4", "mic_to_sjis",
	"mic_to_win1250", "mic_to_win1251", "mic_to_win866", "min", "min_scale", "mod", "mode", "mode_final",
	"money", "mul_d_interval", "multirange", "multirange_adjacent_multirange", "multirange_adjacent_range", "multirange_after_multirange", "multirange_after_range", "multirange_agg_finalfn",
	"multirange_agg_transfn", "multirange_before_multirange", "multirange_before_range", "multirange_cmp", "multirange_contained_by_multirange", "multirange_contained_by_range", "multirange_contains_elem", "multirange_contains_multirange",
	"multirange_contains_range", "multirange_eq", "multirange_ge", "multirange_gist_compress", "multirange_gist_consistent", "multirange_gt", "multirange_in", "multirange_intersect",
	"multirange_intersect_agg_transfn", "multirange_le", "multirange_lt", "multirange_minus", "multirange_ne", "multirange_out", "multirange_overlaps_multirange", "multirange_overlaps_range",
	"multirange_overleft_multirange", "multirange_overleft_range", "multirange_overright_multirange", "multirange_overright_range", "multirange_recv", "multirange_send", "multirange_typanalyze", "multirange_union",
	"multirangesel", "mxid_age", "name", "nameconcatoid", "nameeq", "nameeqtext", "namege", "namegetext",
	"namegt", "namegttext", "nameiclike", "nameicnlike", "nameicregexeq", "nameicregexne", "namein", "namele",
	"nameletext", "namelike", "namelt", "namelttext", "namene", "namenetext", "namenlike", "nameout",
	"namerecv", "nameregexeq", "nameregexne", "namesend", "neqjoinsel", "neqsel", "netmask", "network",
	"network_cmp", "network_eq", "network_ge", "network_gt", "network_larger", "network_le", "network_lt", "network_ne",
	"network_overlap", "network_smaller", "network_sortsupport", "network_sub", "network_subeq", "network_subset_support", "network_sup", "network_supeq",
	"networkjoinsel", "networksel", "nextval", "nlikejoinsel", "nlikesel", "normalize", "notlike", "now",
	"npoints", "nth_value", "ntile", "num_nonnulls", "num_nulls", "numeric", "numeric_abs", "numeric_accum",
	"numeric_accum_inv", "numeric_add", "numeric_avg", "numeric_avg_accum", "numeric_avg_combine", "numeric_avg_deserialize", "numeric_avg_serialize", "numeric_cmp",
	"numeric_combine", "numeric_deserialize", "numeric_div", "numeric_div_trunc", "numeric_eq", "numeric_exp", "numeric_ge", "numeric_gt",
	"numeric_in", "numeric_inc", "numeric_larger", "numeric_le", "numeric_ln", "numeric_log", "numeric_lt", "numeric_mod",
	"numeric_mul", "numeric_ne", "numeric_out", "numeric_pl_pg_lsn", "numeric_poly_avg", "numeric_poly_combine", "numeric_poly_deserialize", "numeric_poly_serialize",
	"numeric_poly_stddev_pop", "numeric_poly_stddev_samp", "numeric_poly_sum", "numeric_poly_var_pop", "numeric_poly_var_samp", "numeric_power", "numeric_recv", "numeric_send",
	"numeric_serialize", "numeric_smaller", "numeric_sortsupport", "numeric_sqrt", "numeric_stddev_pop", "numeric_stddev_samp", "numeric_sub", "numeric_sum",
	"numeric_support", "numeric_uminus", "numeric_uplus", "numeric_var_pop", "numeric_var_samp", "numerictypmodin", "numerictypmodout", "nummultirange",
	"numnode", "numrange", "numrange_subdiff", "obj_description", "octet_length", "oid", "oideq", "oidge",
	"oidgt", "oidin", "oidlarger", "oidle", "oidlt", "oidne", "oidout", "oidrecv",
	"oidsend", "oidsmaller", "oidvectoreq", "oidvectorge", "oidvectorgt", "oidvectorin", "oidvectorle", "oidvectorlt",
	"oidvectorne", "oidvectorout", "oidvectorrecv", "oidvectorsend", "oidvectortypes", "on_pb", "on_pl", "on_ppath",
	"on_ps", "on_sb", "on_sl", "ordered_set_transition", "ordered_set_transition_multi", "overlaps", "overlay", "parse_ident",
	"path", "path_add", "path_add_pt", "path_contain_pt", "path_distance", "path_div_pt", "path_in", "path_inter",
	"path_length", "path_mul_pt", "path_n_eq", "path_n_ge", "path_n_gt", "path_n_le", "path_n_lt", "path_npoints",
	"path_out", "path_recv", "path_send", "path_sub_pt", "pclose", "percent_rank", "percent_rank_final", "percentile_cont",
	"percentile_cont_float8_final", "percentile_cont_float8_multi_final", "percentile_cont_interval_final", "percentile_cont_interval_multi_final", "percentile_disc", "percentile_disc_final", "percentile_disc_multi_final", "pg_cancel_backend",
	"pg_get_viewdef", "pg_size_pretty", "pg_sleep", "pg_terminate_backend", "pg_typeof", "phraseto_tsquery", "pi", "plainto_tsquery",
	"plpgsql_call_handler", "plpgsql_inline_handler", "plpgsql_validator", "point", "point_above", "point_add", "point_below", "point_distance",
	"point_div", "point_eq", "point_horiz", "point_in", "point_left", "point_mul", "point_ne", "point_out",
	"point_recv", "point_right", "point_send", "point_sub", "point_vert", "poly_above", "poly_below", "poly_center",
	"poly_contain", "poly_contain_pt", "poly_contained", "poly_distance", "poly_in", "poly_left", "poly_npoints", "poly_out",
	"poly_overabove", "poly_overbelow", "poly_overlap", "poly_overleft", "poly_overright", "poly_recv", "poly_right", "poly_same",
	"poly_send", "polygon", "popen", "position", "positionjoinsel", "positionsel", "postgresql_fdw_validator", "pow",
	"power", "prefixjoinsel", "prefixsel", "prsd_end", "prsd_headline", "prsd_lextype", "prsd_nexttoken", "prsd_start",
	"pt_contained_circle", "pt_contained_poly", "query_to_xml", "query_to_xml_and_xmlschema", "query_to_xmlschema", "querytree", "quote_ident", "quote_literal",
	"quote_nullable", "radians", "radius", "random", "random_normal", "range_adjacent", "range_adjacent_multirange", "range_after",
	"range_after_multirange", "range_agg", "range_agg_finalfn", "range_agg_transfn", "range_before", "range_before_multirange", "range_cmp", "range_contained_by",
	"range_contained_by_multirange", "range_contains", "range_contains_elem", "range_contains_elem_support", "range_contains_multirange", "range_eq", "range_ge", "range_gist_consistent",
	"range_gist_penalty", "range_gist_picksplit", "range_gist_same", "range_gist_union", "range_gt", "range_in", "range_intersect", "range_intersect_agg",
	"range_intersect_agg_transfn", "range_le", "range_lt", "range_merge", "range_minus", "range_ne", "range_out", "range_overlaps",
	"range_overlaps_multirange", "range_overleft", "range_overleft_multirange", "range_overright", "range_overright_multirange", "range_recv", "range_send", "range_sortsupport",
	"range_typanalyze", "range_union", "rangesel", "rank", "rank_final", "raw_array_subscript_handler", "record_eq", "record_ge",
	"record_gt", "record_image_eq", "record_image_ge", "record_image_gt", "record_image_le", "record_image_lt", "record_image_ne", "record_in",
	"record_larger", "record_le", "record_lt", "record_ne", "record_out", "record_recv", "record_send", "record_smaller",
	"regclass", "regclassin", "regclassout", "regclassrecv", "regclasssend", "regcollationin", "regcollationout", "regcollationrecv",
	"regcollationsend", "regconfigin", "regconfigout", "regconfigrecv", "regconfigsend", "regdictionaryin", "regdictionaryout", "regdictionaryrecv",
	"regdictionarysend", "regexeqjoinsel", "regexeqsel", "regexnejoinsel", "regexnesel", "regexp_count", "regexp_instr", "regexp_like",
	"regexp_match", "regexp_matches", "regexp_replace", "regexp_split_to_array", "regexp_split_to_table", "regexp_substr", "regnamespacein", "regnamespaceout",
	"regnamespacerecv", "regnamespacesend", "regoperatorin", "regoperatorout", "regoperatorrecv", "regoperatorsend", "regoperin", "regoperout",
	"regoperrecv", "regopersend", "regprocedurein", "regprocedureout", "regprocedurerecv", "regproceduresend", "regprocin", "regprocout",
	"regprocrecv", "regprocsend", "regr_avgx", "regr_avgy", "regr_count", "regr_intercept", "regr_r2", "regr_slope",
	"regr_sxx", "regr_sxy", "regr_syy", "regrolein", "regroleout", "regrolerecv", "regrolesend", "regtypein",
	"regtypeout", "regtyperecv", "regtypesend", "repeat", "replace", "reverse", "ri_fkey_cascade_del", "ri_fkey_cascade_upd",
	"ri_fkey_check_ins", "ri_fkey_check_upd", "ri_fkey_noaction_del", "ri_fkey_noaction_upd", "ri_fkey_restrict_del", "ri_fkey_restrict_upd", "ri_fkey_setdefault_del", "ri_fkey_setdefault_upd",
	"ri_fkey_setnull_del", "ri_fkey_setnull_upd", "right", "round", "row_number", "row_security_active", "row_to_json", "rpad",
	"rtrim", "satisfies_hash_partition", "scalargejoinsel", "scalargesel", "scalargtjoinsel", "scalargtsel", "scalarlejoinsel", "scalarlesel",
	"scalarltjoinsel", "scalarltsel", "scale", "schema_to_xml", "schema_to_xml_and_xmlschema", "schema_to_xmlschema", "session_user", "set_bit",
	"set_byte", "set_config", "set_masklen", "setseed", "setval", "setweight", "sha224", "sha256",
	"sha384", "sha512", "shell_in", "shell_out", "shift_jis_2004_to_euc_jis_2004", "shift_jis_2004_to_utf8", "shobj_description", "sign",
	"similar_escape", "similar_to_escape", "sin", "sind", "sinh", "sjis_to_euc_jp", "sjis_to_mic", "sjis_to_utf8",
	"slope", "spg_bbox_quad_config", "spg_box_quad_choose", "spg_box_quad_config", "spg_box_quad_inner_consistent", "spg_box_quad_leaf_consistent", "spg_box_quad_picksplit", "spg_kd_choose",
	"spg_kd_config", "spg_kd_inner_consistent", "spg_kd_picksplit", "spg_poly_quad_compress", "spg_quad_choose", "spg_quad_config", "spg_quad_inner_consistent", "spg_quad_leaf_consistent",
	"spg_quad_picksplit", "spg_range_quad_choose", "spg_range_quad_config", "spg_range_quad_inner_consistent", "spg_range_quad_leaf_consistent", "spg_range_quad_picksplit", "spg_text_choose", "spg_text_config",
	"spg_text_inner_consistent", "spg_text_leaf_consistent", "spg_text_picksplit", "spghandler", "split_part", "sqrt", "starts_with", "statement_timestamp",
	"stddev", "stddev_pop", "stddev_samp", "string_agg", "string_agg_combine", "string_agg_deserialize", "string_agg_finalfn", "string_agg_serialize",
	"string_agg_transfn", "string_to_array", "string_to_table", "strip", "strpos", "substr", "substring", "sum",
	"suppress_redundant_updates_trigger", "system", "system_user", "table_am_handler_in", "table_am_handler_out", "table_to_xml", "table_to_xml_and_xmlschema", "table_to_xmlschema",
	"tan", "tand", "tanh", "text", "text_ge", "text_gt", "text_larger", "text_le",
	"text_lt", "text_pattern_ge", "text_pattern_gt", "text_pattern_le", "text_pattern_lt", "text_smaller", "text_starts_with_support", "textanycat",
	"textcat", "texteq", "texteqname", "textgename", "textgtname", "texticlike", "texticlike_support", "texticnlike",
	"texticregexeq", "texticregexeq_support", "texticregexne", "textin", "textlen", "textlename", "textlike", "textlike_support",
	"textltname", "textne", "textnename", "textnlike", "textout", "textrecv", "textregexeq", "textregexeq_support",
	"textregexne", "textsend", "thesaurus_init", "thesaurus_lexize", "tideq", "tidge", "tidgt", "tidin",
	"tidlarger", "tidle", "tidlt", "tidne", "tidout", "tidrecv", "tidsend", "tidsmaller",
	"time", "time_cmp", "time_eq", "time_ge", "time_gt", "time_hash", "time_hash_extended", "time_in",
	"time_larger", "time_le", "time_lt", "time_mi_interval", "time_mi_time", "time_ne", "time_out", "time_pl_interval",
	"time_recv", "time_send", "time_smaller", "time_support", "timedate_pl", "timeofday", "timestamp", "timestamp_cmp",
	"timestamp_cmp_date", "timestamp_cmp_timestamptz", "timestamp_eq", "timestamp_eq_date", "timestamp_eq_timestamptz", "timestamp_ge", "timestamp_ge_date", "timestamp_ge_timestamptz",
	"timestamp_gt", "timestamp_gt_date", "timestamp_gt_timestamptz", "timestamp_hash", "timestamp_hash_extended", "timestamp_in", "timestamp_larger", "timestamp_le",
	"timestamp_le_date", "timestamp_le_timestamptz", "timestamp_lt", "timestamp_lt_date", "timestamp_lt_timestamptz", "timestamp_mi", "timestamp_mi_interval", "timestamp_ne",
	"timestamp_ne_date", "timestamp_ne_timestamptz", "timestamp_out", "timestamp_pl_interval", "timestamp_recv", "timestamp_send", "timestamp_skipsupport", "timestamp_smaller",
	"timestamp_sortsupport", "timestamp_support", "timestamptypmodin", "timestamptypmodout", "timestamptz", "timestamptz_cmp", "timestamptz_cmp_date", "timestamptz_cmp_timestamp",
	"timestamptz_eq", "timestamptz_eq_date", "timestamptz_eq_timestamp", "timestamptz_ge", "timestamptz_ge_date", "timestamptz_ge_timestamp", "timestamptz_gt", "timestamptz_gt_date",
	"timestamptz_gt_timestamp", "timestamptz_hash", "timestamptz_hash_extended", "timestamptz_in", "timestamptz_larger", "timestamptz_le", "timestamptz_le_date", "timestamptz_le_timestamp",
	"timestamptz_lt", "timestamptz_lt_date", "timestamptz_lt_timestamp", "timestamptz_mi", "timestamptz_mi_interval", "timestamptz_ne", "timestamptz_ne_date", "timestamptz_ne_timestamp",
	"timestamptz_out", "timestamptz_pl_interval", "timestamptz_recv", "timestamptz_send", "timestamptz_smaller", "timestamptztypmodin", "timestamptztypmodout", "timetypmodin",
	"timetypmodout", "timetz", "timetz_cmp", "timetz_eq", "timetz_ge", "timetz_gt", "timetz_hash", "timetz_hash_extended",
	"timetz_in", "timetz_larger", "timetz_le", "timetz_lt", "timetz_mi_interval", "timetz_ne", "timetz_out", "timetz_pl_interval",
	"timetz_recv", "timetz_send", "timetz_smaller", "timetzdate_pl", "timetztypmodin", "timetztypmodout", "timezone", "to_ascii",
	"to_bin", "to_char", "to_date", "to_hex", "to_json", "to_jsonb", "to_number", "to_oct",
	"to_regclass", "to_regcollation", "to_regnamespace", "to_regoper", "to_regoperator", "to_regproc", "to_regprocedure", "to_regrole",
	"to_regtype", "to_regtypemod", "to_timestamp", "to_tsquery", "to_tsvector", "transaction_timestamp", "translate", "trigger_in",
	"trigger_out", "trim_array", "trim_scale", "trunc", "ts_debug", "ts_delete", "ts_filter", "ts_headline",
	"ts_lexize", "ts_match_qv", "ts_match_tq", "ts_match_tt", "ts_match_vq", "ts_parse", "ts_rank", "ts_rank_cd",
	"ts_rewrite", "ts_stat", "ts_token_type", "ts_typanalyze", "tsm_handler_in", "tsm_handler_out", "tsmatchjoinsel", "tsmatchsel",
	"tsmultirange", "tsq_mcontained", "tsq_mcontains", "tsquery_and", "tsquery_cmp", "tsquery_eq", "tsquery_ge", "tsquery_gt",
	"tsquery_le", "tsquery_lt", "tsquery_ne", "tsquery_not", "tsquery_or", "tsquery_phrase", "tsqueryin", "tsqueryout",
	"tsqueryrecv", "tsquerysend", "tsrange", "tsrange_subdiff", "tstzmultirange", "tstzrange", "tstzrange_subdiff", "tsvector_cmp",
	"tsvector_concat", "tsvector_eq", "tsvector_ge", "tsvector_gt", "tsvector_le", "tsvector_lt", "tsvector_ne", "tsvector_to_array",
	"tsvector_update_trigger", "tsvector_update_trigger_column", "tsvectorin", "tsvectorout", "tsvectorrecv", "tsvectorsend", "txid_current", "txid_current_if_assigned",
	"txid_current_snapshot", "txid_snapshot_in", "txid_snapshot_out", "txid_snapshot_recv", "txid_snapshot_send", "txid_snapshot_xip", "txid_snapshot_xmax", "txid_snapshot_xmin",
	"txid_status", "txid_visible_in_snapshot", "uhc_to_utf8", "unicode_assigned", "unicode_version", "unique_key_recheck", "unistr", "unknownin",
	"unknownout", "unknownrecv", "unknownsend", "unnest", "upper", "upper_inc", "upper_inf", "utf8_to_big5",
	"utf8_to_euc_cn", "utf8_to_euc_jis_2004", "utf8_to_euc_jp", "utf8_to_euc_kr", "utf8_to_euc_tw", "utf8_to_gb18030", "utf8_to_gbk", "utf8_to_iso8859",
	"utf8_to_iso8859_1", "utf8_to_johab", "utf8_to_koi8r", "utf8_to_koi8u", "utf8_to_shift_jis_2004", "utf8_to_sjis", "utf8_to_uhc", "utf8_to_win",
	"uuid_cmp", "uuid_eq", "uuid_extract_timestamp", "uuid_extract_version", "uuid_ge", "uuid_gt", "uuid_hash", "uuid_hash_extended",
	"uuid_in", "uuid_le", "uuid_lt", "uuid_ne", "uuid_out", "uuid_recv", "uuid_send", "uuid_skipsupport",
	"uuid_sortsupport", "uuidv4", "uuidv7", "var_pop", "var_samp", "varbit", "varbit_in", "varbit_out",
	"varbit_recv", "varbit_send", "varbit_support", "varbitcmp", "varbiteq", "varbitge", "varbitgt", "varbitle",
	"varbitlt", "varbitne", "varbittypmodin", "varbittypmodout", "varchar", "varchar_support", "varcharin", "varcharout",
	"varcharrecv", "varcharsend", "varchartypmodin", "varchartypmodout", "variance", "version", "void_in", "void_out",
	"void_recv", "void_send", "websearch_to_tsquery", "width", "width_bucket", "win1250_to_latin2", "win1250_to_mic", "win1251_to_iso",
	"win1251_to_koi8r", "win1251_to_mic", "win1251_to_win866", "win866_to_iso", "win866_to_koi8r", "win866_to_mic", "win866_to_win1251", "win_to_utf8",
	"window_cume_dist_support", "window_dense_rank_support", "window_ntile_support", "window_percent_rank_support", "window_rank_support", "window_row_number_support", "xid", "xid8_larger",
	"xid8_smaller", "xid8cmp", "xid8eq", "xid8ge", "xid8gt", "xid8in", "xid8le", "xid8lt",
	"xid8ne", "xid8out", "xid8recv", "xid8send", "xideq", "xideqint4", "xidin", "xidneq",
	"xidneqint4", "xidout", "xidrecv", "xidsend", "xml", "xml_in", "xml_is_well_formed", "xml_is_well_formed_content",
	"xml_is_well_formed_document", "xml_out", "xml_recv", "xml_send", "xmlagg", "xmlcomment", "xmlconcat2", "xmlexists",
	"xmltext", "xmlvalidate", "xpath", "xpath_exists",
};

static BOOL SPIsWhitespace(unichar c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v' || c == 0xA0 || c == 0x2028 || c == 0x2029 || c == 0xFEFF;
}

static BOOL SPIsIdentifierStart(unichar c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80;
}

static BOOL SPIsTagCharacter(unichar c)
{
	return SPIsIdentifierStart(c) || (c >= '0' && c <= '9');
}

static BOOL SPIsIdentifierCharacter(unichar c)
{
	return SPIsTagCharacter(c) || c == '$';
}

static BOOL SPIsDigit(unichar c)
{
	return c >= '0' && c <= '9';
}

@implementation SPPostgresSQLTokenizer

+ (NSSet<NSString *> *)keywords
{
	static NSSet *keywords;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableSet *set = [NSMutableSet set];
		for (size_t i = 0; i < sizeof(SPPostgresKeywordWords) / sizeof(*SPPostgresKeywordWords); i++) [set addObject:@(SPPostgresKeywordWords[i])];
		for (size_t i = 0; i < sizeof(SPPostgresTypeNames) / sizeof(*SPPostgresTypeNames); i++) [set addObject:@(SPPostgresTypeNames[i])];
		keywords = [set copy];
	});
	return keywords;
}

+ (NSArray<NSString *> *)functionNames
{
	static NSArray *names;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableSet *set = [NSMutableSet set];
		for (size_t i = 0; i < sizeof(SPPostgresFunctionNameWords) / sizeof(*SPPostgresFunctionNameWords); i++) [set addObject:@(SPPostgresFunctionNameWords[i]).lowercaseString];
		names = [[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] retain]; // kept for the process (MRC)
	});
	return names;
}

+ (NSArray<SPPostgresSQLToken *> *)tokensInString:(NSString *)string range:(NSRange)range
{
	NSMutableArray *tokens = [NSMutableArray array];
	if (!string || range.length == 0 || NSMaxRange(range) > string.length) return tokens;

	NSUInteger length = range.length;
	unichar *chars = malloc(length * sizeof(unichar));
	if (!chars) return tokens;
	[string getCharacters:chars range:range];
	NSSet *keywords = [self keywords];

	NSUInteger i = 0;
	while (i < length) {
		unichar c = chars[i];
		unichar next = (i + 1 < length) ? chars[i + 1] : 0;
		SPPostgresTokenKind kind = SPPostgresTokenOther;
		NSUInteger j = i + 1;

		if (SPIsWhitespace(c)) {
			kind = SPPostgresTokenWhitespace;
			while (j < length && SPIsWhitespace(chars[j])) j++;
		}
		else if (c == '-' && next == '-') {
			kind = SPPostgresTokenComment;
			j = i + 2;
			while (j < length && chars[j] != '\n' && chars[j] != '\r') j++;
		}
		else if (c == '/' && next == '*') {
			kind = SPPostgresTokenComment;
			NSUInteger depth = 1;
			j = i + 2;
			while (j < length && depth > 0) {
				if (chars[j] == '/' && j + 1 < length && chars[j + 1] == '*') { depth++; j += 2; }
				else if (chars[j] == '*' && j + 1 < length && chars[j + 1] == '/') { depth--; j += 2; }
				else j++;
			}
			j = MIN(j, length);
		}
		else if (c == '\'') {
			kind = SPPostgresTokenString;
			j = [self endOfQuoteStartingAt:i chars:chars length:length quote:'\'' backslashEscapes:NO];
		}
		else if (c == '"') {
			kind = SPPostgresTokenQuotedIdentifier;
			j = [self endOfQuoteStartingAt:i chars:chars length:length quote:'"' backslashEscapes:NO];
		}
		else if (c == '$' && next >= '0' && next <= '9') {
			kind = SPPostgresTokenParameter;
			while (j < length && SPIsDigit(chars[j])) j++;
		}
		else if (c == '$') {
			// $tag$ … $tag$ (the tag is empty or an identifier without $)
			NSUInteger k = i + 1;
			if (k < length && SPIsIdentifierStart(chars[k])) {
				k++;
				while (k < length && SPIsTagCharacter(chars[k])) k++;
			}
			if (k < length && chars[k] == '$') {
				NSUInteger tagLength = k + 1 - i;
				NSUInteger end = length;
				for (NSUInteger m = k + 1; m + tagLength <= length; m++) {
					if (chars[m] == '$' && memcmp(chars + m, chars + i, tagLength * sizeof(unichar)) == 0) {
						end = m + tagLength;
						break;
					}
				}
				kind = SPPostgresTokenString;
				j = end;
			}
		}
		else if (SPIsDigit(c) || (c == '.' && SPIsDigit(next))) {
			// 1, 1.5, .5, 1e3, 1.5e-3, 1_000. 0x1F is the number 0 then the identifier x1F.
			kind = SPPostgresTokenNumber;
			j = i;
			while (j < length && (SPIsDigit(chars[j]) || (chars[j] == '_' && j > i && SPIsDigit(chars[j - 1]) && j + 1 < length && SPIsDigit(chars[j + 1])))) j++;
			if (j < length && chars[j] == '.') {
				j++;
				while (j < length && SPIsDigit(chars[j])) j++;
			}
			if (j < length && (chars[j] == 'e' || chars[j] == 'E')) {
				NSUInteger k = j + 1;
				if (k < length && (chars[k] == '+' || chars[k] == '-')) k++;
				if (k < length && SPIsDigit(chars[k])) {
					while (k < length && SPIsDigit(chars[k])) k++;
					j = k;
				}
			}
		}
		else if (SPIsIdentifierStart(c)) {
			j = i + 1;
			while (j < length && SPIsIdentifierCharacter(chars[j])) j++;
			if (j == i + 1 && j < length && chars[j] == '\'' && (c == 'E' || c == 'e' || c == 'b' || c == 'B' || c == 'x' || c == 'X' || c == 'n' || c == 'N')) {
				// E'…' (backslash escapes), B'…', X'…', N'…': one string token with its prefix
				kind = SPPostgresTokenString;
				j = [self endOfQuoteStartingAt:j chars:chars length:length quote:'\'' backslashEscapes:(c == 'E' || c == 'e')];
			}
			else {
				NSString *word = [[NSString stringWithCharacters:chars + i length:j - i] lowercaseString];
				kind = [keywords containsObject:word] ? SPPostgresTokenKeyword : SPPostgresTokenIdentifier;
			}
		}

		SPPostgresSQLToken *token = [[SPPostgresSQLToken alloc] initWithKind:kind range:NSMakeRange(range.location + i, j - i)];
		[tokens addObject:token];
		[token release];
		i = j;
	}

	free(chars);
	return tokens;
}

/// The end of the quote opening at chars[start]: doubled quotes (and \x with backslashEscapes) stay inside;
/// an unterminated one runs to length.
+ (NSUInteger)endOfQuoteStartingAt:(NSUInteger)start chars:(const unichar *)chars length:(NSUInteger)length quote:(unichar)quote backslashEscapes:(BOOL)escapes
{
	NSUInteger j = start + 1;
	while (j < length) {
		if (escapes && chars[j] == '\\') {
			j += 2;
			continue;
		}
		if (chars[j] == quote) {
			if (j + 1 < length && chars[j + 1] == quote) {
				j += 2;
				continue;
			}
			return j + 1;
		}
		j++;
	}
	return length;
}

@end
