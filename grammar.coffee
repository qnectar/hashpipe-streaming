stream = require 'stream'
util = require 'util'
peg = require 'pegjs'
h = require 'highland'
_ = require 'underscore'
request = require 'request'
jsonstream = require 'JSONStream'

request = request.defaults({headers: 'user-agent': 'hashpipe'})

# Helpers

inspect = (o, trim=false) ->
    s = util.inspect(o, {colors: true, depth: null})
    s = s.replace(/\n/g, '') if trim
    return s
log = console.log
ilog = _.compose log, inspect
makeBar = (n, c) -> (c for i in [0..n-1]).join('')
hr = -> console.log makeBar 80, '-'

# Define grammar
# ------------------------------------------------------------------------------
# 
# TODO
# * Aliasing
# * JSON obj/list parsing
# * @ commands
# Integrate from existing?

parser = peg.buildParser """
start = phrases

// Phrases (lines)

phrases =
    head:phrase
    tail:(sep p:phrase { return p; })*
    { return [head].concat(tail); }
phrase = aliasing / sections

// Sections (commands and sub-phrases)

sections =
    head:section
    tail:piped_sections
    { return [{command: head}].concat(tail); }
piped_section =
    dpipe s:section { return {command: s, type: 'map'}; } /
    pipe s:section { return {command: s, type: 'pipe'}; }
piped_sections = (piped_section)*
section = sub_phrase / reg_phrase
reg_phrase =
    head:method
    tail:(Space a:arg { return a; })*
    { return [head].concat(tail); }
sub_phrase = oparen p:phrase cparen { return {sub: p}; }

// Aliasing

aliasing =
    "alias =" w:word { return [{alias: w}]; }

// Variables

variable =
    "$" v:word { return {var: v}; }

// Letters, words, quotes

letter = [a-zA-Z0-9.:/*+<>_-] / esc_pipe / newline
anyletter = newline / [^\\"]
quoted = quot ls:anyletter* quot { return ls.join(''); }

numeral = [0-9]
number = ns:(_ns:numeral+ { return _ns.join(''); })
         ds:("." _ds:numeral+ { return _ds.join(''); })?
    {
        var n = parseInt(ns); var d = 0;
        if (ds != null) d = parseInt(ds) / Math.pow(10.0, ds.length);
        return n + d;
    }

word = ls:letter+ { return ls.join(''); }

method = sub_phrase / variable
    / n:number {console.log('got method: ' + n); return {number: n};}
    / q:quoted {return {string: q};}
    / w:word {console.log('got method: ' + w); return {method: w};}

arg = sub_phrase / variable
    / n:number {return {number: n};}
    / q:quoted {return {string: q};}
    / w:word {return {string: w};}

// Digits etc.

oparen = space "(" space
cparen = space ")" space
sep = space "\\n" / ";" space
dpipe = space "||" space
pipe = space "|" space
esc_pipe = "\\\\|" { return "|" }
quot = "\\""
newline = "\\\\n" { return "\\n" }

space = [ \\t]* "\\n" [ \\t]+ / [ \\t]*
Space = [ \\t]* "\\n" [ \\t]+ / [ \\t]+
"""

# Test script
# ------------------------------------------------------------------------------

repos_subpipe = """
get https://api.github.com/users/substack/repos
    | pluck url
    || (
        split "/"
        | tail 3
        | join "..."
    )
    | collect
"""

single_object = """
((get https://api.github.com/users/substack/repos | reverse)) | (pluck name | reverse) | (reverse)
"""

midi_double_stream = """
onMidiPad 36 | < 50 || * 2
    || (bar "=" | : "smallr " | inspect bar)
onMidiPad 36 | > 50 | * 2
    || (bar "=" | : "bigger " | inspect bar)
"""

midi_take_4 = """
on midi nanoPAD2:36:on | inspect | take 4
"""

wemo_sensor_light = """
on maia:wemo change:sensors/Sensor-1_0-221213L010139A/state
    | istrue
    | inspect
    | do lifx turn_on
on maia:wemo change:sensors/Sensor-1_0-221213L010139A/state
    | isfalse
    | inspect
    | do lifx turn_off
"""

# Define methods
# ------------------------------------------------------------------------------

somata = require 'somata'
eventStream = require 'somata-highland'
client = new somata.Client
onMidiPad = (ins, pad) ->
    console.log 'the pad is ' + util.inspect pad
    eventStream(client, 'midi', "nanoPAD2:#{ pad }:on")

get = (ins, url) ->
    s = h()
    request url: url, json: true, (err, res, got) ->
        console.log 'got'
        console.log got
        s.write got
        s.end()
    return s.flatten()

parseJson = (ins, query='*') ->
    logit = (v) -> console.log 'parsing: ' + v
    ins.through(jsonstream.parse(query))

join = (ins, delim='') ->
    ins.collect().map (together) ->
        together.join(delim)

reverse = (ins, l) ->
    ins.collect().consume (err, x, push, next) ->
        x.reverse()
        push null, i for i in x
        push null, h.nil

split = (ins, delimiter) ->
    ins.consume (err, x, push, next) ->
        if x == h.nil
            push null, x
        else
            push null, _x for _x in x.split(delimiter)
            next()

collect = (ins) ->
    ins.collect()

logPlain = (ins) ->
    console.log ins
inspectAll = (ins, tag=null) ->
    ins.doto (i) -> inspectOne i, tag
inspectOne = (i, tag=null) ->
    tag = if tag? then '.' + tag else ''
    log "[inspect#{ tag }] #{ inspect i }"

wrap = (sf) ->
    (ins, args...) ->
        ins[sf](args...)

wrapsome = (ms) ->
    _.object ms.map (sf) ->
        [sf, wrap sf]

wrapsync = (ms) ->
    _.object _.pairs(ms).map ([mn, mf]) ->
        [mn, (i, a..., cb) -> cb null, mf(i, a...)]

streammethods = wrapsome ['head', 'last', 'take', 'pluck']

methods = _.extend {
    # Generators
    # ---------------------------------------
    get
    on: (ins, service, event) ->
        eventStream(client, service, event)
    list: (ins, args...) ->
        h(args)
    bar: (ins, n, c='-') ->
        h([makeBar n, c])
    'list-users': (ins, args...) ->
        get(ins, 'https://api.github.com/users')
}, wrapsync {
    # Item methods
    # ---------------------------------------
    '*': (i, n) -> i * n
    '-': (i, n) -> i - n
    '+': (i, n) ->
        console.log 'incoming: ' + inspect i
        console.log 'with: ' + inspect n
        i + n
}, {
    'get-that': (i, args...) ->
        get null, i
    log: (i, args...) ->
        console.log i
        h [i]
    echo: (i, args...) ->
        echoed = args.slice(0).map(inspect).join(' ')
        console.log echoed
        h [echoed]
}, {
    # Stream methods
    # ---------------------------------------
    reverse
    join
    split
    collect
    inspect: inspectAll
    do: (ins, service, method, args...) ->
        ins.doto ->
            client.remote service, method, args..., (err, got) ->
                console.log 'ok: ' + got
    tail: (ins, n) -> ins.collect().flatMap (a) -> h(a[-1*n..])
    ':': (ins, pre) -> ins.map (s) -> pre.concat s
    '++': (ins, post) -> ins.map (s) -> s.concat post
    '<': (ins, n) -> ins.filter (i) -> i < n
    '>': (ins, n) -> ins.filter (i) -> i > n
    'istrue': (ins, n) -> ins.filter (i) -> i
    'isfalse': (ins, n) -> ins.filter (i) -> !i
}, streammethods

# Parsing
# ------------------------------------------------------------------------------

execScript = (script, cb) ->
    parsed = parser.parse(script)
    console.log '[parsed]:  ' + util.inspect parsed, depth: null, colors: true
    hr()
    phrases = parsed.map(parsePhrase)
    console.log '[phrases]: ' + util.inspect phrases, depth: null, colors: true
    hr()

    ins = h()
    executed = phrases.reduce(execPhrase, ins)
    if err = executed.error
        cb err
    else
        executed.toArray (a) ->
            cb null, a

parsePhrase = (phrase) ->
    phrase.map(parseSection)

parseSection = (section) ->
    log "[parseSection]: " + inspect section
    command = section.command
    if sub_phrase = command.sub
        log '[parseSection] sub : ' + inspect sub_phrase
        [(parsePhrase sub_phrase), [], section.type || 'pipe']
    else
        [method, args...] = command
        [method, args, section.type || 'pipe']

execPhrase = (ins, phrase) ->
    log "[execPhrase] Executing #{ phrase.length } sections for phrase:"
    for p in phrase
        console.log '    * ' + inspect p
    hr()
    return phrase.reduce(execSection, ins)

parseLiteral = (o) ->
    if o.number?
        return o.number
    if o.string?
        return o.string

parseArgs = (args, ins=null) ->
    console.log '[parseArgs] ' + util.inspect {args}, color: true
    args.map (arg) ->
        if sub_phrase = arg.sub
            console.log '[parseArgs] sub: ' + inspect sub_phrase
            return execPhrase (parsePhrase sub_phrase), ins.fork()
        else
            return parseLiteral arg

execSection = (ins, [method, args, pipe_type]) ->
    console.log '[execSection] ' + util.inspect {method, args}, color: true
    args = if args? then parseArgs args, ins else []

    if pipe_type == 'map'
        # Execute a map by feeding each item of the input stream to the method
        return ins.flatMap (i) ->
            console.log '[exec.map] ' + inspect method
            #execSection(i, [method, args, ])
            execMethod(i, method, args)
    else
        execMethod(ins, method, args)

        # isarray method
        # if pipe_type == 'map'
        #     ins.flatMap (i) ->
        #         console.log '[exec.sub.map] mapping in ' + i
        #         ms = h([i])
        #         execPhrase(ms, method)


execMethod = (ins, method, args) ->
    # Single value (but not a single string)
    if args.length == 0
        literal = parseLiteral method
        if literal?
            return h([literal])

    if _.isArray method
        # Execute by creating a pipe out of the sub phrase
        # TODO: Dry out
        console.log '[exec.sub.pipe] ' + method
        execPhrase(ins, method)

    else if method_name = method.method
        # Do whatever normal piping operation the method expects
        console.log '[exec.pipe] ' + method_name
        if method_fn = getMethod(method_name)
            return method_fn(ins, args...)
        else
            log '[ERROR] Could not find method: ' + inspect method
            return error: "Could not find method"

    else
        log '[ERROR] Could not find method: ' + inspect method
        return error: "Could not find method"

getMethod = (method) ->
    methods[method]

printCommand = ([method, args, pipe_type]) ->
    args_str = if args.length then inspect args.join(', ') else null
    command_str = method + '(' + args_str + ')'
    log 'COMMAND: ' + command_str

# Repl
# ------------------------------------------------------------------------------

readline = require 'readline'
rl = readline.createInterface
    input: process.stdin
    output: process.stdout

rl.setPrompt ' ~> '

# Interpret input as scripts and run
rl.prompt()
rl.on 'line', (script) ->
    script = script.trim()
    script = 'id' if !script.length
    execScript script, (err, a) ->
        hr()
        log a
        rl.prompt()

