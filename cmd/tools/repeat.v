module main

import os
import flag
import time
import term
import math
import scripting
import v.util

struct CmdResult {
mut:
	runs int
	cmd string
	icmd int
	outputs []string
	oms map[string][]int
	summary map[string]Aints
	timings []int
	atiming Aints
}
struct Context {
mut:
	count int
	warmup int
	show_help bool
	show_result bool
	fail_on_regress_percent int
	verbose bool
	commands []string
	results []CmdResult
	cline string // a terminal clearing line
}

struct Aints {
	values []int
mut:
	imin int
	imax int
	average f64
	stddev f64
}
fn new_aints(vals []int) Aints {
	mut res := Aints{ values: vals }
	mut sum := i64(0)
	mut imin :=  math.max_i32
	mut imax := -math.max_i32
	for i in vals {
		sum+=i
		if i < imin {
			imin = i
		}
		if i > imax {
			imax = i
		}
	}
	res.imin = imin
	res.imax = imax
	if vals.len > 0 {
		res.average = sum / f64(vals.len)
	}
	//
	mut devsum := f64(0.0)
	for i in vals {
		x := f64(i) - res.average
		devsum += (x * x)
	}
	res.stddev = math.sqrt( devsum / f64(vals.len) )
	return res
}
fn (a Aints) str() string { return util.bold('${a.average:9.3f}') + 'ms ± σ: ${a.stddev:-5.1f}ms, min … max: ${a.imin}ms … ${a.imax}ms' }

const (
	max_fail_percent = 100000
)
fn main(){
	mut context := Context{}
	context.parse_options()
	context.run()
	context.show_diff_summary()
}

fn (mut context Context) parse_options() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application(os.file_name(os.executable()))
	fp.version('0.0.1')
	fp.description('Repeat command(s) and collect statistics. NB: you have to quote each command.')
	fp.arguments_description('CMD1 CMD2 ...')
	fp.skip_executable()
	fp.limit_free_args_to_at_least(1)
	context.count = fp.int('count', `c`, 10, 'Repetition count')
	context.warmup = fp.int('warmup', `w`, 2, 'Warmup runs')
	context.show_help = fp.bool('help', `h`, false, 'Show this help screen.')
	context.verbose = fp.bool('verbose', `v`, false, 'Be more verbose.')
	context.fail_on_regress_percent = fp.int('fail_percent', `f`, max_fail_percent, 'Fail with 1 exit code, when first cmd is X% slower than the rest (regression).')
	if context.show_help {
		println(fp.usage())
		exit(0)
	}
	if context.verbose {
		scripting.set_verbose(true)
	}
	context.commands = fp.finalize() or {
		eprintln('Error: ' + err)
		exit(1)
	}
	context.results = []CmdResult{ len: context.commands.len, init: CmdResult{} }
	context.cline = '\r' + term.h_divider('')
}

fn (mut context Context) clear_line() {
	print(context.cline)
}

fn (mut context Context) run() {
	for icmd, cmd in context.commands {
		mut runs := 0
		mut duration := 0
		mut sum := 0
		mut oldres := ''
		println('Command: $cmd')
		if context.warmup > 0 {
			for i in 1..context.warmup+1 {
				print('\r warming up run: ${i:4}/${context.warmup:-4} for ${cmd:-50s} took ${duration:6} ms ...')
				mut sw := time.new_stopwatch({})
				os.exec(cmd) or { continue }
				duration = int(sw.elapsed().milliseconds())
			}
		}
		context.clear_line()
		for i in 1..(context.count+1) {
			avg := f64(sum)/f64(i)
			print('\rAverage: ${avg:9.3f}ms | run: ${i:4}/${context.count:-4} | took ${duration:6} ms')
			if context.show_result {
				print(' | result: ${oldres:-s}')
			}
			mut sw := time.new_stopwatch({})
			res := os.exec(cmd) or {
				eprintln('${i:10} failed runnning cmd: $cmd')
				continue
			}
			duration = int(sw.elapsed().milliseconds())
			if res.exit_code != 0 {
				eprintln('${i:10} non 0 exit code for cmd: $cmd')
				continue
			}
			context.results[icmd].outputs << res.output.trim_right('\r\n').replace('\r\n', '\n').split("\n")
			context.results[icmd].timings << duration
			sum += duration
			runs++
			oldres = res.output.replace('\n', ' ')
		}
		context.results[icmd].cmd = cmd
		context.results[icmd].icmd = icmd
		context.results[icmd].runs = runs
		context.results[icmd].atiming = new_aints(context.results[icmd].timings)
		context.clear_line()
		print('\r')
		mut m := map[string][]int
		for o in context.results[icmd].outputs {
			x := o.split(':')
			if x.len > 1 {
				k := x[0]
				v := x[1].trim_left(' ').int()
				m[k] << v
			}
		}
		context.results[icmd].oms = m
		oms := context.results[icmd].oms
		mut summary := map[string]Aints{}
		for k,v in oms {
			s := new_aints(v)
			println('  $k: $s')
			summary[k] = s
		}
		context.results[icmd].summary = summary
		//println('')
	}
}
fn (mut context Context) show_diff_summary() {
	context.results.sort_with_compare(fn (a, b &CmdResult) int {
		if a.atiming.average < b.atiming.average {
			return -1
		}
		if a.atiming.average > b.atiming.average {
			return 1
		}
		return 0
	})
	println('Summary (commands are ordered by ascending mean time), after $context.count repeats:')
	base := context.results[0].atiming.average
	mut first_cmd_percentage := f64(100.0)
	for i, r in context.results {
		cpercent := (r.atiming.average / base) * 100 - 100
		first_marker := if r.icmd == 0 { util.bold('>') } else { ' ' }
		if r.icmd == 0 {
			first_cmd_percentage = cpercent
		}
		println(' ${first_marker}${(i+1):3} | ${cpercent:6.1f}% slower | ${r.cmd:-55s} | ${r.atiming}')
	}
	if context.fail_on_regress_percent == max_fail_percent || context.results.len < 2 {
		return
	}
	fail_threshold_max := f64(context.fail_on_regress_percent)
	if first_cmd_percentage > fail_threshold_max {
		print('Performance regression detected, failing since ')
		println('${first_cmd_percentage:5.1f}% > ${fail_threshold_max:5.1f}% threshold.')
		exit(1)
	}
}