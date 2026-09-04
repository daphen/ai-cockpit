import { useEffect, useRef, useState } from "react"

interface Props {
  seedKey: string
  size: 16 | 20 | 44
  running?: boolean
  tone?: OrbTone
  tones?: OrbTone[]
  className?: string
}

const vertexSource = `#version 300 es
in vec2 p;
out vec2 tex;
void main(){tex=p*.5+.5;gl_Position=vec4(p,0.,1.);}`

const fragmentSource = `#version 300 es
precision highp float;
in vec2 tex;
out vec4 frag;
uniform vec4 ph;
uniform vec3 colA,colB,colC,ring;
uniform float ringWidth;
float hash(vec2 p){p=fract(p*vec2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);}
float noise(vec2 p){vec2 i=floor(p),f=fract(p),u=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1,0)),u.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),u.x),u.y);}
float fbm(vec2 p){float v=0.,a=.5;for(int i=0;i<3;i++){v+=a*noise(p);p=p*2.03+vec2(17.31,9.17);a*=.54;}return v;}
void main(){
 vec2 uv=tex*2.-1.;float r=length(uv),aa=fwidth(r)*1.5;
 float c=cos(-.76),sn=sin(-.76);vec2 u=mat2(c,-sn,sn,c)*uv;
 float ga=1.2*.7*sin(ph.x),gc=cos(ga),gs=sin(ga);u=mat2(gc,-gs,gs,gc)*u;
 vec2 d1=vec2(cos(ph.x),sin(ph.y));vec2 d2=vec2(cos(ph.y+2.1),sin(ph.z+1.));
 vec2 d3=vec2(cos(ph.z+4.2),sin(ph.w+3.1));vec2 d4=vec2(cos(ph.w+.7),sin(ph.x+2.6));
 vec2 b=u*(.8/1.35);vec2 q=vec2(fbm(b+d1),fbm(b+vec2(3.7,1.9)+d2));
 float vraw=fbm(b+1.5*(q-.45)+d4),v=smoothstep(.22,.62,vraw);
 float praw=fbm(b*(1.1+.2*1.2)+1.5*.8*vec2(q.y,-q.x)+vec2(9.1,4.7)+d3);
 float pl=smoothstep(.30,.60,praw),ga3=ph.z+1.7;
 pl-=.18*(dot(u,vec2(cos(ga3),sin(ga3)))*.5+.5);
 float vb=v+(.55-.5)*.6;vb+=.22*dot(u,vec2(cos(ph.y),sin(ph.y)));vb+=.10*(.6-r);
 float fw=mix(.10,.45,.96),s1=smoothstep(.55-fw,.55+fw,vb);vec3 color=mix(colA,colB,s1);
 float s2=smoothstep(.80-fw*.6,.92,pl+(.55-.5)*.3);color=mix(color,colC,s2*.92);
 float cr=exp(-pow(vb-.55,2.)/.0032);color+=colC*cr*(.55*.05);color*=1.-.18*smoothstep(.55,1.,r);
 float fieldMask=1.-smoothstep(.98-aa,.98+aa,r);float ringMask=smoothstep(1.-ringWidth-aa,1.-ringWidth+aa,r)*(1.-smoothstep(1.-aa,1.+aa,r));
 color=mix(color,ring,ringMask);frag=vec4(color,max(fieldMask,ringMask));
}`

type OrbTone = "green" | "orange" | "sky"

interface RenderEntry {
  node: HTMLCanvasElement
  context: CanvasRenderingContext2D
  size: 16 | 20 | 44
  seed: number
  tones: OrbTone[]
  fail: () => void
}

let sharedRenderer: SharedOrbRenderer | null | undefined

export function Orb({ seedKey, size, running = true, tone = "sky", tones, className = "" }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const [fallback, setFallback] = useState(false)
  const toneKey = (tones?.length ? tones : [tone]).join(",")

  useEffect(() => {
    if (!running || !canvas.current) return
    if (sharedRenderer === undefined) sharedRenderer = SharedOrbRenderer.create()
    if (!sharedRenderer) { setFallback(true); return }
    return sharedRenderer.add(canvas.current, size, fnvSeed(seedKey), toneKey.split(",") as OrbTone[], () => setFallback(true))
  }, [running, seedKey, size, toneKey])

  if (!running) return null
  if (fallback) return <span className={`orb-fallback ${className}`} aria-hidden="true" />
  return <canvas ref={canvas} className={`aurora-orb ${className}`} style={{ width: size, height: size }} aria-hidden="true" />
}

class SharedOrbRenderer {
  private readonly surface: HTMLCanvasElement
  private readonly gl: WebGL2RenderingContext
  private readonly program: WebGLProgram
  private readonly entries = new Map<HTMLCanvasElement, RenderEntry>()
  private readonly light = matchMedia("(prefers-color-scheme: light)")
  private readonly reduced = matchMedia("(prefers-reduced-motion: reduce)")
  private readonly uniforms: Record<"ph" | "colA" | "colB" | "colC" | "ring" | "ringWidth", WebGLUniformLocation | null>
  private frame = 0
  private lost = false

  static create() {
    const surface = document.createElement("canvas")
    surface.width = 88
    surface.height = 88
    const gl = surface.getContext("webgl2", { alpha: true, antialias: true })
    if (!gl) return null
    const program = makeProgram(gl)
    if (!program) return null
    return new SharedOrbRenderer(surface, gl, program)
  }

  private constructor(surface: HTMLCanvasElement, gl: WebGL2RenderingContext, program: WebGLProgram) {
    this.surface = surface
    this.gl = gl
    this.program = program
    this.uniforms = {
      ph: gl.getUniformLocation(program, "ph"),
      colA: gl.getUniformLocation(program, "colA"),
      colB: gl.getUniformLocation(program, "colB"),
      colC: gl.getUniformLocation(program, "colC"),
      ring: gl.getUniformLocation(program, "ring"),
      ringWidth: gl.getUniformLocation(program, "ringWidth"),
    }
    gl.viewport(0, 0, surface.width, surface.height)
    gl.useProgram(program)
    const buffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
    const position = gl.getAttribLocation(program, "p")
    gl.enableVertexAttribArray(position)
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0)
    surface.addEventListener("webglcontextlost", event => {
      event.preventDefault()
      this.lost = true
      cancelAnimationFrame(this.frame)
      for (const entry of this.entries.values()) entry.fail()
    })
    this.light.addEventListener("change", this.redraw)
    this.reduced.addEventListener("change", this.redraw)
    document.addEventListener("visibilitychange", this.visibilityChanged)
  }

  add(node: HTMLCanvasElement, size: 16 | 20 | 44, seed: number, tones: OrbTone[], fail: () => void) {
    const context = node.getContext("2d")
    if (!context || this.lost) { fail(); return }
    const dpr = Math.min(devicePixelRatio || 1, 2)
    node.width = size * dpr
    node.height = size * dpr
    this.entries.set(node, { node, context, size, seed, tones, fail })
    this.redraw()
    return () => {
      this.entries.delete(node)
      if (!this.entries.size) {
        cancelAnimationFrame(this.frame)
        this.frame = 0
      }
    }
  }

  private visibilityChanged = () => {
    if (document.hidden) {
      cancelAnimationFrame(this.frame)
      this.frame = 0
    } else {
      this.redraw()
    }
  }

  private redraw = () => {
    cancelAnimationFrame(this.frame)
    this.draw()
  }

  private draw = () => {
    this.frame = 0
    if (document.hidden || this.lost || !this.entries.size) return
    const palettes = new Map<string, ReturnType<typeof orbPalette>>()
    for (const entry of this.entries.values()) {
      const key = entry.tones.join(",")
      let palette = palettes.get(key)
      if (!palette) {
        palette = combinedPalette(entry.tones, this.light.matches)
        palettes.set(key, palette)
      }
      this.drawEntry(entry, palette)
    }
    if (!this.reduced.matches) this.frame = requestAnimationFrame(this.draw)
  }

  private drawEntry(entry: RenderEntry, palette: ReturnType<typeof orbPalette>) {
    const gl = this.gl
    gl.clearColor(0, 0, 0, 0)
    gl.clear(gl.COLOR_BUFFER_BIT)
    gl.uniform3fv(this.uniforms.colA, palette.a)
    gl.uniform3fv(this.uniforms.colB, palette.b)
    gl.uniform3fv(this.uniforms.colC, palette.c)
    gl.uniform3fv(this.uniforms.ring, palette.ring)
    gl.uniform1f(this.uniforms.ringWidth, (Math.max(1.25, entry.size * .065) + (this.light.matches ? 1 : 0)) / entry.size * 2)
    const now = Date.now() * (entry.size >= 40 ? 3.5 : 1.8)
    gl.uniform4f(this.uniforms.ph, phase(now, 47000) + entry.seed * 6.2832, phase(now, 61000) + entry.seed * 17.9, phase(now, 83000) + entry.seed * 29.3, phase(now, 29000) + entry.seed * 41.7)
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
    entry.context.clearRect(0, 0, entry.node.width, entry.node.height)
    entry.context.drawImage(this.surface, 0, 0, entry.node.width, entry.node.height)
  }
}

function makeProgram(gl: WebGL2RenderingContext) {
  const compile = (type: number, source: string) => {
    const shader = gl.createShader(type)
    if (!shader) return null
    gl.shaderSource(shader, source)
    gl.compileShader(shader)
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) { gl.deleteShader(shader); return null }
    return shader
  }
  const vertex = compile(gl.VERTEX_SHADER, vertexSource)
  const fragment = compile(gl.FRAGMENT_SHADER, fragmentSource)
  if (!vertex || !fragment) return null
  const program = gl.createProgram()
  if (!program) return null
  gl.attachShader(program, vertex)
  gl.attachShader(program, fragment)
  gl.linkProgram(program)
  gl.deleteShader(vertex)
  gl.deleteShader(fragment)
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) { gl.deleteProgram(program); return null }
  return program
}

export function orbTone(tool?: string): "green" | "orange" | "sky" {
  if (["edit", "write", "create", "str_replace", "bash-write"].includes(tool ?? "")) return "green"
  if (["bash", "shell", "request_user_bash"].includes(tool ?? "")) return "orange"
  return "sky"
}

function fnvSeed(value: string) {
  let hash = 2166136261
  for (let i = 0; i < value.length; i++) hash = Math.imul(hash ^ value.charCodeAt(i), 16777619) >>> 0
  return (hash % 100000) / 100000
}

function phase(now: number, period: number) {
  return (now % period) / period * Math.PI * 2
}

function cssRgb(token: string): [number, number, number] {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(token).trim()
  const value = Number.parseInt(raw.slice(1), 16)
  return [((value >> 16) & 255) / 255, ((value >> 8) & 255) / 255, (value & 255) / 255]
}

function combinedPalette(tones: OrbTone[], light: boolean) {
  const colors = (tones.length ? tones : ["sky"]).map(tone => cssRgb(`--${tone}`))
  if (colors.length === 1) return orbPalette(colors[0], light)
  const bucket = (index: number) => {
    const members = colors.filter((_, colorIndex) => colorIndex % 3 === index)
    const values = members.length ? members : [colors[index % colors.length]]
    return values.reduce<[number, number, number]>((sum, color) => [sum[0] + color[0], sum[1] + color[1], sum[2] + color[2]], [0, 0, 0]).map(value => value / values.length) as [number, number, number]
  }
  const tint = (rgb: [number, number, number], shift: number) => {
    const [hue, saturation, lightness] = rgbToHsl(rgb)
    return hsl(hue, Math.max(.65, saturation), Math.max(.18, Math.min(.82, lightness + shift)))
  }
  return {
    a: tint(bucket(0), -.16),
    b: tint(bucket(1), 0),
    c: tint(bucket(2), .18),
    ring: orbPalette(colors[0], light).ring,
  }
}

function orbPalette(rgb: [number, number, number], light: boolean) {
  const [h, rawSat] = rgbToHsl(rgb)
  const sat = rawSat < .05 ? 0 : Math.max(.75, rawSat)
  const warm = h < .45
  const orange = h < .17
  const lift = .10 * Math.max(0, Math.min(1, (h - .565) / .06))
  const oLift = light && orange ? .047 : 0
  const a = orange ? hsl(h - .027, sat, .359 + oLift) : hsl(h + (warm ? .02 : .03), sat * .60, (light ? .30 : .24) + lift * .6)
  const b = orange ? hsl(h, sat * .867, .55 + oLift) : hsl(h, sat * (warm ? .70 : .55), (light ? .58 : .52) + lift)
  const c = orange ? hsl(h + .05, sat * .789, .733 + oLift) : hsl(h + (warm ? .045 : .96), sat * .35, (light ? .84 : .80) + lift * .5)
  return { a, b, c, ring: hsl(h, sat * .5, light ? .34 : .82) }
}

function rgbToHsl([r, g, b]: [number, number, number]): [number, number, number] {
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  const l = (max + min) / 2
  if (!d) return [0, 0, l]
  const s = d / (1 - Math.abs(2 * l - 1))
  const h = max === r ? ((g - b) / d + (g < b ? 6 : 0)) / 6 : max === g ? ((b - r) / d + 2) / 6 : ((r - g) / d + 4) / 6
  return [h, s, l]
}

function hsl(h: number, s: number, l: number): [number, number, number] {
  h = (h % 1 + 1) % 1
  const a = s * Math.min(l, 1 - l)
  const channel = (n: number) => { const k = (n + h * 12) % 12; return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)) }
  return [channel(0), channel(8), channel(4)]
}
