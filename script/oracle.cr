require "file_utils"
require "http/client"
require "json"

# Real Tailwind, for the scripts beside this file: its npm package, fetched
# once into script/.tailwind/<version>, and run under bun or node. Tailwind
# is JavaScript, so asking it anything needs one of them; the few lines of
# BRIDGE are all the JavaScript there is. Nothing here ships with the shard.
class Oracle
  # The Tailwind CSS release the tables and the reference are written from.
  VERSION = "4.3.3"

  # Answers one request a line, as JSON: Tailwind's design-system API and
  # its build, with nothing of this project's in it.
  BRIDGE = <<-JS
    const tw = require("./dist/lib.js")
    const read = (name) => require("node:fs").readFileSync(__dirname + "/" + name, "utf8")
    const loadStylesheet = async (id, base) => ({ path: id, base, content: read(id.replace(/^tailwindcss\\//, "")) })
    const systems = []
    const answer = {
      load: async ({ css }) => systems.push(await tw.__unstable__loadDesignSystem(css + "\\n@tailwind utilities;")) - 1,
      keys: ({ id, kind }) => [...systems[id].utilities.keys(kind)],
      classes: ({ id }) => systems[id].getClassList().map(([name, about]) => [name, about.modifiers ?? []]),
      variants: ({ id }) => systems[id].getVariants().filter((variant) => !variant.isArbitrary && !variant.values.length).map((variant) => variant.name),
      order: ({ id }) => systems[id].getVariants().map((variant) => variant.name),
      parse: ({ id, names }) => names.map((name) => [...systems[id].parseCandidate(name)][0] ?? null),
      compile: ({ id, names }) => names.map((name) => {
        try {
          return [...systems[id].parseCandidate(name)].flatMap((candidate) => systems[id].compileAstNodes(candidate)).map((found) => found.node)
        } catch {
          return []
        }
      }),
      build: async ({ css, classes }) => (await tw.compile(css, { base: "/", loadStylesheet })).build(classes),
    }
    ;(async () => {
      for await (const line of require("node:readline").createInterface({ input: process.stdin })) {
        const request = JSON.parse(line)
        process.stdout.write(JSON.stringify(await answer[request.ask](request)) + "\\n")
      }
    })()
    JS

  getter dir : String

  def initialize
    @dir = "#{__DIR__}/.tailwind/#{VERSION}"
    fetch unless File.exists?("#{@dir}/dist/lib.js")
    File.write("#{@dir}/bridge.cjs", BRIDGE)
    runtime = Process.find_executable("bun") || Process.find_executable("node") || abort "bun or node is needed to run Tailwind"
    @process = Process.new(runtime, ["#{@dir}/bridge.cjs"], input: :pipe, output: :pipe, error: :inherit)
  end

  # A file of Tailwind's package.
  def read(name : String) : String
    File.read("#{@dir}/#{name}")
  end

  # A design system over `css`, as the id the other requests take.
  def load(css : String) : Int32
    ask("load", css: css).as_i
  end

  def keys(id : Int32, kind : String) : Array(String)
    ask("keys", id: id, kind: kind).as_a.map(&.as_s)
  end

  # Every class Tailwind suggests, with the modifiers it suggests for it.
  def classes(id : Int32) : Array({String, Array(String)})
    Array({String, Array(String)}).from_json(ask("classes", id: id).to_json)
  end

  # The variants that take no value, in Tailwind's order.
  def variants(id : Int32) : Array(String)
    ask("variants", id: id).as_a.map(&.as_s)
  end

  # Every variant, in Tailwind's order.
  def order(id : Int32) : Array(String)
    ask("order", id: id).as_a.map(&.as_s)
  end

  # Each name as Tailwind reads it, or null.
  def parse(id : Int32, names : Array(String)) : Array(JSON::Any)
    ask("parse", id: id, names: names).as_a
  end

  # The rules each name compiles to, as Tailwind's own nodes.
  def compile(id : Int32, names : Array(String)) : Array(Array(JSON::Any))
    ask("compile", id: id, names: names).as_a.map(&.as_a)
  end

  # Tailwind's stylesheet for `classes` over the CSS `css`.
  def build(css : String, classes : Array(String)) : String
    ask("build", css: css, classes: classes).as_s
  end

  private def ask(name : String, **fields) : JSON::Any
    @process.input.puts({ask: name}.merge(fields).to_json)
    @process.input.flush
    JSON.parse(@process.output.gets || abort "Tailwind stopped answering at #{name}")
  end

  # Tailwind's npm package, unpacked with the system's tar. A download that
  # stalls or stops part way leaves nothing behind.
  private def fetch : Nil
    uri = URI.parse("https://registry.npmjs.org/tailwindcss/-/tailwindcss-#{VERSION}.tgz")
    STDERR.puts "fetching #{uri}"
    partial = "#{@dir}.part"
    FileUtils.rm_rf(partial)
    Dir.mkdir_p(partial)
    client = HTTP::Client.new(uri)
    client.connect_timeout = 15.seconds
    client.read_timeout = 30.seconds
    client.get(uri.request_target) do |response|
      abort "#{uri} answered #{response.status_code}" unless response.success?
      status = Process.run("tar", ["-xzf", "-", "--strip-components=1", "-C", partial], input: response.body_io, error: :inherit)
      abort "could not unpack #{uri}" unless status.success?
    end
    FileUtils.rm_rf(@dir)
    File.rename(partial, @dir)
  rescue error : IO::Error | Socket::Error
    FileUtils.rm_rf("#{@dir}.part")
    abort "could not fetch Tailwind: #{error.message}"
  end
end
