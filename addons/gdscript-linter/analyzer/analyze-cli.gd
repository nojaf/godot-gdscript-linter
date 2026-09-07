# GDScript Linter - Code quality analyzer for GDScript
# https://poplava.itch.io
@tool
extends SceneTree
## CLI runner for code analysis
## Usage: godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- [options] [paths...]
## Options:
##   --config <path>    Use custom config file (default: gdlint.json)
##   --format <type>    Output format: console, json, sarif, clickable, html, github
##   --severity <level> Minimum severity to report: info, warning, critical
##   --check <checks>   Comma-separated list of checks to run
##   --no-ignore        Bypass all gdlint:ignore directives
##   --check-members    Load every script; report compile failures and self.foo.bar that resolves to nothing
##   --check-unused-functions  Report functions nothing in the project references
##   --check-exports    Report object-typed @export vars that nothing null-guards
##   --check-node-paths Report $Path, %Name and get_node("Path") that no attached scene has

const AnalysisConfigClass = preload("res://addons/gdscript-linter/analyzer/analysis-config.gd")
const CodeAnalyzerClass = preload("res://addons/gdscript-linter/analyzer/code-analyzer.gd")
const AnalysisResultClass = preload("res://addons/gdscript-linter/analyzer/analysis-result.gd")
const FileResultClass = preload("res://addons/gdscript-linter/analyzer/file-result.gd")
const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")
const HtmlReportGenerator = preload("res://addons/gdscript-linter/analyzer/html-report-generator.gd")

var _target_paths: Array[String] = []  # Multiple paths to analyze
var _output_format: String = "console"  # "console", "json", "clickable", "html", "github"
var _output_file: String = ""  # For HTML output
var _no_ignore: bool = false  # Bypass all gdlint:ignore directives
var _check_members: bool = false  # Also load every script and verify self.foo.bar chains
var _check_unused_functions: bool = false  # Also report functions nothing references
var _check_exports: bool = false  # Also report @export object vars with no null guard
var _check_node_paths: bool = false  # Also verify $Path and %Name against the scenes
var _source_index: GDLintSourceIndex = null  # Structure, built once per run
var _config_path: String = ""  # Custom config file path
var _severity_filter: String = ""  # Minimum severity: "info", "warning", "critical"
var _check_filter: Array[String] = []  # Specific checks to run
var _top_limit: int = 0  # Limit to top N issues (0 = no limit)
var _json_indent: String = "\t"  # Indent for json/sarif output ("--spaces N"; "" = compact)
var _exit_code: int = 0

func _init() -> void:
	_parse_arguments()
	_run_analysis()
	quit(_exit_code)

# gdlint:ignore-function:long-function - CLI argument parsing with many options
func _parse_arguments() -> void:
	var args := OS.get_cmdline_user_args()

	var i := 0
	while i < args.size():
		var arg: String = args[i]

		# Check if this is a flag or a positional path argument
		if arg.begins_with("-"):
			match arg:
				"--path":
					# Legacy single path support
					if i + 1 < args.size():
						var raw_path: String = args[i + 1]
						var normalized := raw_path.replace("/", "\\") if OS.has_feature("windows") else raw_path
						_target_paths.append(normalized)
						i += 1
				"--config":
					if i + 1 < args.size():
						_config_path = args[i + 1]
						i += 1
				"--format":
					if i + 1 < args.size():
						_output_format = args[i + 1]
						i += 1
				"--severity":
					if i + 1 < args.size():
						_severity_filter = args[i + 1].to_lower()
						i += 1
				"--check":
					if i + 1 < args.size():
						var checks: String = args[i + 1]
						for check in checks.split(","):
							var trimmed := check.strip_edges()
							if not trimmed.is_empty():
								_check_filter.append(trimmed)
						i += 1
				"--top":
					if i + 1 < args.size():
						_top_limit = int(args[i + 1])
						i += 1
				"--spaces":
					if i + 1 < args.size():
						# Indent width for json/sarif; 0 = compact single line
						_json_indent = " ".repeat(maxi(0, int(args[i + 1])))
						i += 1
				"--clickable":
					_output_format = "clickable"
				"--json":
					_output_format = "json"
				"--sarif":
					_output_format = "sarif"
				"--html":
					_output_format = "html"
				"--github":
					_output_format = "github"
				"--output", "-o":
					if i + 1 < args.size():
						_output_file = args[i + 1]
						i += 1
				"--no-ignore":
					_no_ignore = true
				"--check-members":
					_check_members = true
				"--check-unused-functions":
					_check_unused_functions = true
				"--check-exports":
					_check_exports = true
				"--check-node-paths":
					_check_node_paths = true
				"--help", "-h":
					_print_help()
					quit(0)
					return
		else:
			# Positional argument - treat as a path to analyze
			var normalized := arg.replace("/", "\\") if OS.has_feature("windows") else arg
			_target_paths.append(normalized)

		i += 1

	# Default to current directory if no paths specified
	if _target_paths.is_empty():
		_target_paths.append("res://")

# gdlint:ignore-function:print-statement,long-function - CLI help output
func _print_help() -> void:
	print("")
	print("GDScript Linter - Code Quality Analyzer for GDScript")
	print("")
	print("Usage:")
	print("  godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- [options] [paths...]")
	print("")
	print("Arguments:")
	print("  [paths...]        Files or directories to analyze (default: res://)")
	print("")
	print("Options:")
	print("  --config <path>   Path to config file (default: gdlint.json)")
	print("  --format <type>   Output format: console, json, sarif, clickable, html, github (default: console)")
	print("  --severity <lvl>  Minimum severity to report: info, warning, critical")
	print("  --check <checks>  Comma-separated list of checks to run (e.g., long-function,high-complexity)")
	print("  --top <N>         Show only top N issues sorted by priority")
	print("  --spaces <N>      Indent width for json/sarif output (0 = compact; default: tab)")
	print("  --json            Shorthand for --format json")
	print("  --sarif           Shorthand for --format sarif (SARIF 2.1.0 for GitHub/JetBrains)")
	print("  --clickable       Shorthand for --format clickable (Godot Output panel format)")
	print("  --html            Shorthand for --format html (generates HTML report)")
	print("  --github          Shorthand for --format github (GitHub Actions annotations)")
	print("  --output, -o <f>  Write output to a file instead of stdout (--sarif/--json/--html)")
	print("  --no-ignore       Bypass all gdlint:ignore directives (show everything)")
	print("  --check-members   Also load every script: report ones that fail to compile")
	print("                    and self.foo.bar accesses that resolve to nothing")
	print("  --check-unused-functions")
	print("                    Report functions nothing in the project references")
	print("  --check-exports   Report object-typed @export vars that nothing null-guards")
	print("  --check-node-paths")
	print("                    Report $Path, %Name and get_node(\"Path\") that name no node")
	print("                    in any scene the script is attached to")
	print("  --path <dir>      Legacy: analyze single path (use positional args instead)")
	print("  --help, -h        Show this help message")
	print("")
	print("Examples:")
	print("  # Analyze current project")
	print("  godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd")
	print("")
	print("  # Analyze specific directories")
	print("  godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- src/ scripts/")
	print("")
	print("  # Use custom config and GitHub Actions output")
	print("  godot --headless --script ... -- --config gdlint-ci.json --format github src/")
	print("")
	print("  # Show only critical issues for specific checks")
	print("  godot --headless --script ... -- --severity critical --check high-complexity,long-function")
	print("")
	print("Exit codes:")
	print("  0 = No issues (or only filtered-out issues)")
	print("  1 = Warnings found")
	print("  2 = Critical issues found")
	print("")

func _run_analysis() -> void:
	var config := _load_config()
	if _no_ignore:
		config.respect_ignore_directives = false
	_apply_check_filter_to_config(config)

	# Fold explicitly-targeted addon paths into included_addons so they are scanned
	for target_path in _target_paths:
		var normalized := target_path.replace("\\", "/")
		if normalized.contains("addons/"):
			var addon_name := AnalysisConfigClass.get_addon_name(target_path)
			if not addon_name.is_empty() and not config.included_addons.has(addon_name):
				config.included_addons.append(addon_name)

	var analyzer = CodeAnalyzerClass.new(config)

	# Analyze all paths and merge results
	var merged_result = null
	for target_path in _target_paths:
		var result = analyzer.analyze_directory(target_path)
		if merged_result == null:
			merged_result = result
		else:
			_merge_results(merged_result, result)

	if _check_members or _check_unused_functions or _check_exports or _check_node_paths:
		_source_index = _build_source_index(merged_result)
		if _source_index == null:
			return  # _build_source_index already reported why

	if _check_members:
		_run_member_check(merged_result, config)

	if _check_unused_functions:
		_run_unused_function_check(merged_result, config)

	if _check_exports:
		_run_export_check(merged_result, config)

	if _check_node_paths:
		_run_node_path_check(merged_result, config)

	# Apply severity filter if specified
	if not _severity_filter.is_empty():
		_apply_severity_filter(merged_result)

	# Apply priority sort and limit if --top specified
	if _top_limit > 0:
		_apply_priority_sort_and_limit(merged_result)

	match _output_format:
		"json":
			_output_json(merged_result)
		"sarif":
			_output_sarif(merged_result)
		"clickable":
			_output_clickable(merged_result)
		"html":
			_output_html(merged_result)
		"github":
			_output_github(merged_result)
		_:
			_output_console(merged_result)

	_exit_code = merged_result.get_exit_code()


# The member check runs over exactly the files the analysis covered, so it inherits the
# same scoping (excludes, .gdignore, addon rules) for free.
func _run_member_check(result, config) -> void:
	var paths: Array = []
	for file_result in result.file_results:
		paths.append(file_result.file_path)

	var member_check := GDLintMemberCheck.new()
	for issue in member_check.run(_source_index, paths, config.respect_ignore_directives):
		result.add_issue(issue)


# References are searched project-wide inside the check itself, so a narrowed
# analysis scope cannot turn a live function into a false positive.
# Structure for the checks that need it, built once per run. A failure here is
# fatal: reporting nothing looks exactly like a clean project, so the run must
# stop and say why rather than quietly checking less.
func _build_source_index(result) -> GDLintSourceIndex:
	var excluded: Array = []
	var scanning_addons := false
	for file_result in result.file_results:
		if String(file_result.file_path).replace("res://", "").begins_with("addons/"):
			scanning_addons = true
			break
	if not scanning_addons:
		excluded.append(ProjectSettings.globalize_path("res://addons"))

	var index := GDLintSourceIndex.new()
	if not index.build(excluded):
		push_error("gdscript-linter: %s" % index.error)
		printerr("gdscript-linter: %s" % index.error)
		_exit_code = 3
		return null
	return index


func _run_unused_function_check(result, config) -> void:
	var paths: Array = []
	for file_result in result.file_results:
		paths.append(file_result.file_path)

	var unused_check := GDLintUnusedFunctionCheck.new()
	for issue in unused_check.run(_source_index, paths, config.respect_ignore_directives):
		result.add_issue(issue)


func _run_export_check(result, config) -> void:
	var paths: Array = []
	for file_result in result.file_results:
		paths.append(file_result.file_path)

	var export_check := GDLintExportCheck.new()
	for issue in export_check.run(_source_index, paths, config.respect_ignore_directives):
		result.add_issue(issue)


# Scenes are read project-wide inside the check, because the scene that attaches
# a script is not necessarily under the directory being analyzed.
func _run_node_path_check(result, config) -> void:
	var paths: Array = []
	for file_result in result.file_results:
		paths.append(file_result.file_path)

	var node_path_check := GDLintNodePathCheck.new()
	for issue in node_path_check.run(_source_index, paths, config.respect_ignore_directives):
		result.add_issue(issue)


# Load config from specified path or auto-detect
func _load_config() -> Resource:
	# If custom config path specified, load it
	if not _config_path.is_empty():
		var config = AnalysisConfigClass.new()
		config.load_from_json(_config_path)
		return config

	# Load from project root gdlint.json
	return AnalysisConfigClass.load_project_config_auto("res://")


# Disable checks not in the filter list
func _apply_check_filter_to_config(config: Resource) -> void:
	if _check_filter.is_empty():
		return

	# Map check IDs to config property names
	var check_id_to_prop := {
		"file-length": "check_file_length",
		"long-function": "check_function_length",
		"long-line": "check_long_lines",
		"todo-comment": "check_todo_comments",
		"print-statement": "check_print_statements",
		"empty-function": "check_empty_functions",
		"magic-number": "check_magic_numbers",
		"commented-code": "check_commented_code",
		"missing-type-hint": "check_missing_types",
		"missing-return-type": "check_missing_return_type",
		"too-many-params": "check_parameters",
		"deep-nesting": "check_nesting",
		"high-complexity": "check_cyclomatic_complexity",
		"god-class": "check_god_class",
		"naming-class": "check_naming_conventions",
		"naming-function": "check_naming_conventions",
		"naming-signal": "check_naming_conventions",
		"naming-const": "check_naming_conventions",
		"naming-enum": "check_naming_conventions",
		"unused-variable": "check_unused_variables",
		"unused-parameter": "check_unused_parameters",
		"ascii-violation": "check_ascii_only",
		"strict-limit": "check_strict_limits",
		"sealed-violation": "check_sealed",
	}

	# Disable all checks first
	for prop in check_id_to_prop.values():
		if config.get(prop) != null:
			config.set(prop, false)

	# Enable only the requested checks
	for check_id in _check_filter:
		if check_id_to_prop.has(check_id):
			var prop: String = check_id_to_prop[check_id]
			config.set(prop, true)


# Merge second result into first
func _merge_results(target, source) -> void:
	target.issues.append_array(source.issues)
	target.ignored_issues.append_array(source.ignored_issues)
	target.file_results.append_array(source.file_results)
	target.files_analyzed += source.files_analyzed
	target.total_lines += source.total_lines
	target.analysis_time_ms += source.analysis_time_ms


# Filter issues by minimum severity
func _apply_severity_filter(result) -> void:
	var min_severity: int
	match _severity_filter:
		"critical":
			min_severity = IssueClass.Severity.CRITICAL
		"warning":
			min_severity = IssueClass.Severity.WARNING
		_:  # "info" or any other value
			return  # No filtering needed

	result.issues = result.issues.filter(func(issue): return issue.severity >= min_severity)


# Sort issues by priority and limit to top N
func _apply_priority_sort_and_limit(result) -> void:
	# Sort by severity (desc), then by extracted value (desc), then by line number
	result.issues.sort_custom(_compare_issue_priority)

	# Truncate to top N
	if result.issues.size() > _top_limit:
		result.issues = result.issues.slice(0, _top_limit)


func _compare_issue_priority(a, b) -> bool:
	# Higher severity first
	if a.severity != b.severity:
		return a.severity > b.severity

	# Within same severity, extract numeric value from message (higher = worse)
	var a_val := _extract_issue_value(a)
	var b_val := _extract_issue_value(b)
	if a_val != b_val:
		return a_val > b_val

	# Same file: earlier line number first
	if a.file_path == b.file_path:
		return a.line < b.line

	# Different files: alphabetical
	return a.file_path < b.file_path


func _extract_issue_value(issue) -> int:
	# Extract numbers from message like "complexity 54" or "exceeds 30 lines (158)"
	var regex := RegEx.new()
	regex.compile("\\((\\d+)\\)|complexity (\\d+)|(\\d+) lines")
	var result := regex.search(issue.message)
	if result:
		for i in range(1, 4):
			if result.get_string(i) != "":
				return int(result.get_string(i))
	return 0


# gdlint:ignore-function:print-statement - CLI JSON output
func _output_json(result) -> void:
	_write_or_print(JSON.stringify(result.to_dict(), _json_indent), "JSON report")


# Godot prints its version banner to stdout before this script ever runs, so a
# redirect like `--sarif > results.sarif` captures the banner too and the file is
# not valid JSON. Writing the payload to --output sidesteps stdout entirely.
func _write_or_print(payload: String, label: String) -> void:
	if _output_file.is_empty():
		print(payload)
		return

	var file := FileAccess.open(_output_file, FileAccess.WRITE)
	if file == null:
		push_error("Failed to write %s to: %s" % [label, _output_file])
		return
	file.store_string(payload)
	file.close()
	print("%s written to: %s" % [label, _output_file])

# gdlint:ignore-function:print-statement - CLI SARIF 2.1.0 output
func _output_sarif(result) -> void:
	# Static Analysis Results Interchange Format 2.1.0 (https://sarifweb.azurewebsites.net/)
	# Imports into GitHub code scanning and JetBrains IDEs.
	var sarif := {
		"$schema": "https://json.schemastore.org/sarif-2.1.0.json",
		"version": "2.1.0",
		"runs": [{
			"tool": {
				"driver": {
					"name": "GDScript Linter",
					"version": _get_tool_version(),
					"informationUri": "https://poplava.itch.io",
					"rules": _sarif_rules(result),
				}
			},
			"results": _sarif_results(result),
		}],
	}
	_write_or_print(JSON.stringify(sarif, _json_indent), "SARIF report")

# Distinct rule ids seen in this run, as minimal reportingDescriptor entries.
func _sarif_rules(result) -> Array:
	var seen := {}
	var rules := []
	for issue in result.issues:
		if not seen.has(issue.check_id):
			seen[issue.check_id] = true
			rules.append({"id": issue.check_id})
	return rules

func _sarif_results(result) -> Array:
	var results := []
	for issue in result.issues:
		var region := {"startLine": issue.line}
		# SARIF columns are 1-based; our column is 0-based and usually 0 (unset).
		# Omit when 0 so strict validators accept the file.
		if issue.column > 0:
			region["startColumn"] = issue.column + 1
		results.append({
			"ruleId": issue.check_id,
			"level": _sarif_level(issue.severity),
			"message": {"text": issue.message},
			"locations": [{
				"physicalLocation": {
					"artifactLocation": {"uri": _sarif_uri(issue.file_path)},
					"region": region,
				}
			}],
		})
	return results

func _sarif_level(severity: int) -> String:
	match severity:
		IssueClass.Severity.CRITICAL:
			return "error"
		IssueClass.Severity.WARNING:
			return "warning"
		_:
			return "note"

# Repo-relative URI: strip res:// and normalize separators to forward slashes.
func _sarif_uri(file_path: String) -> String:
	var uri := file_path
	if uri.begins_with("res://"):
		uri = uri.substr(6)
	return uri.replace("\\", "/")

func _get_tool_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/gdscript-linter/plugin.cfg") == OK:
		return str(cfg.get_value("plugin", "version", "unknown"))
	return "unknown"

# gdlint:ignore-function:print-statement,long-function - CLI clickable output
func _output_clickable(result) -> void:
	# Format that Godot Output panel makes clickable
	print("")
	print("=== Code Analysis Results ===")
	print("Files: %d | Lines: %d | Issues: %d" % [
		result.files_analyzed, result.total_lines, result.issues.size()
	])
	print("")

	# Group by severity
	var critical: Array = result.get_issues_by_severity(IssueClass.Severity.CRITICAL)
	var warnings: Array = result.get_issues_by_severity(IssueClass.Severity.WARNING)
	var info: Array = result.get_issues_by_severity(IssueClass.Severity.INFO)

	if critical.size() > 0:
		print("--- CRITICAL (%d) ---" % critical.size())
		for issue in critical:
			print(issue.get_clickable_format())
		print("")

	if warnings.size() > 0:
		print("--- WARNINGS (%d) ---" % warnings.size())
		for issue in warnings:
			print(issue.get_clickable_format())
		print("")

	if info.size() > 0:
		print("--- INFO (%d) ---" % info.size())
		for issue in info:
			print(issue.get_clickable_format())
		print("")

	print("Debt Score: %d | Time: %dms" % [result.get_total_debt_score(), result.analysis_time_ms])


# gdlint:ignore-function:print-statement - GitHub Actions annotation format
func _output_github(result) -> void:
	# GitHub Actions workflow commands format:
	# ::error file={file},line={line}::{message}
	# ::warning file={file},line={line}::{message}
	# ::notice file={file},line={line}::{message}
	for issue in result.issues:
		var level: String
		match issue.severity:
			IssueClass.Severity.CRITICAL:
				level = "error"
			IssueClass.Severity.WARNING:
				level = "warning"
			_:
				level = "notice"

		# Get relative file path (strip res:// prefix)
		var file_path: String = issue.file_path
		if file_path.begins_with("res://"):
			file_path = file_path.substr(6)

		# Format: ::level file=path,line=N::message
		print("::%s file=%s,line=%d::[%s] %s" % [
			level,
			file_path,
			issue.line,
			issue.check_id,
			issue.message
		])


# gdlint:ignore-function:print-statement - Console output formatting
func _output_console(result) -> void:
	_print_console_header(result)
	_print_top_files_by_size(result)
	_print_top_files_by_debt(result)
	_print_critical_issues(result)
	_print_long_functions(result)
	_print_pinned_exception_issues(result)
	_print_todo_comments(result)
	_print_console_footer()

# gdlint:ignore-function:print-statement - CLI console output
func _print_console_header(result) -> void:
	print("")
	print("=" .repeat(60))
	print("GDSCRIPT LINTER - CODE QUALITY REPORT")
	print("=" .repeat(60))
	print("")
	print("SUMMARY")
	print("-" .repeat(40))
	print("Total files analyzed: %d" % result.files_analyzed)
	print("Total lines of code: %d" % result.total_lines)
	print("Critical issues: %d" % result.get_critical_count())
	print("Warnings: %d" % result.get_warning_count())
	print("Info: %d" % result.get_info_count())
	print("Total debt score: %d" % result.get_total_debt_score())
	print("Analysis time: %dms" % result.analysis_time_ms)
	print("")

# gdlint:ignore-function:print-statement - CLI console output
func _print_top_files_by_size(result) -> void:
	print("TOP 10 FILES BY SIZE")
	print("-" .repeat(40))
	var by_size: Array = result.file_results.duplicate()
	by_size.sort_custom(func(a, b): return a.line_count > b.line_count)
	for i in range(mini(10, by_size.size())):
		var f = by_size[i]
		print("%4d lines | %s" % [f.line_count, f.file_path])
	print("")

# gdlint:ignore-function:print-statement - CLI console output
func _print_top_files_by_debt(result) -> void:
	print("TOP 10 FILES BY DEBT SCORE")
	print("-" .repeat(40))
	var by_debt: Array = result.file_results.duplicate()
	by_debt.sort_custom(func(a, b): return a.debt_score > b.debt_score)
	for i in range(mini(10, by_debt.size())):
		var f = by_debt[i]
		if f.debt_score == 0:
			break
		print("Score %3d | %4d lines | %s" % [f.debt_score, f.line_count, f.file_path])
	print("")

# gdlint:ignore-function:print-statement - CLI console output
func _print_critical_issues(result) -> void:
	var critical: Array = result.get_issues_by_severity(IssueClass.Severity.CRITICAL)
	if critical.size() == 0:
		return
	print("CRITICAL ISSUES (Fix Immediately)")
	print("-" .repeat(40))
	for issue in critical:
		print("  %s" % issue.get_clickable_format())
	print("")

# gdlint:ignore-function:print-statement - CLI console output
func _print_long_functions(result) -> void:
	print("LONG FUNCTIONS")
	print("-" .repeat(40))
	var long_func_issues: Array = result.issues.filter(func(i): return i.check_id == "long-function")
	long_func_issues.sort_custom(func(a, b): return a.severity > b.severity)
	for i in range(mini(15, long_func_issues.size())):
		var issue = long_func_issues[i]
		print("  %s" % issue.get_clickable_format())
	print("")

# gdlint:ignore-function:print-statement - CLI console output
func _print_pinned_exception_issues(result) -> void:
	var pinned_issues: Array = result.issues.filter(func(i): return i.check_id.ends_with("-exceeded") or i.check_id.ends_with("-improved") or i.check_id.ends_with("-unnecessary"))
	if pinned_issues.size() == 0:
		return
	print("PINNED EXCEPTION ALERTS")
	print("-" .repeat(40))
	for issue in pinned_issues:
		print("  %s" % issue.get_clickable_format())
	print("")


# gdlint:ignore-function:print-statement - CLI console output
func _print_todo_comments(result) -> void:
	var todo_issues: Array = result.issues.filter(func(i): return i.check_id == "todo-comment")
	if todo_issues.size() == 0:
		return
	print("TODO/FIXME COMMENTS (%d total)" % todo_issues.size())
	print("-" .repeat(40))
	for i in range(mini(10, todo_issues.size())):
		var issue = todo_issues[i]
		print("  %s" % issue.get_clickable_format())
	if todo_issues.size() > 10:
		print("  ... and %d more" % (todo_issues.size() - 10))
	print("")

# gdlint:ignore-function:print-statement - CLI console output
func _print_console_footer() -> void:
	print("=" .repeat(60))
	print("Run with --clickable for Godot Output panel clickable links")
	print("Run with --json for machine-readable output")
	print("=" .repeat(60))


# gdlint:ignore-function:print-statement - CLI HTML output
func _output_html(result) -> void:
	var output_path := _output_file if _output_file != "" else "code_quality_report.html"

	var html := HtmlReportGenerator.generate(result)

	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file:
		file.store_string(html)
		file.close()
		print("HTML report saved to: %s" % output_path)
	else:
		push_error("Failed to write HTML report to: %s" % output_path)
