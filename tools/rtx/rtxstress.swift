// Carga de computacao Metal na RTX (NullMoth) por N segundos, para ver temperatura/uso subirem.
// So recebe a RTX se o nome do processo ("rtxstress") estiver em /Library/GPUBundles/nvmtl-allow.txt.
// Uso: rtxstress [segundos=60]
import Metal
import Foundation
let secs = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let devs = MTLCopyAllDevices()
for d in devs { print("GPU: \(d.name)\(d.isLowPower ? " (baixo consumo)" : "")") }
guard let dev = devs.first(where: { $0.name.lowercased().contains("nvidia") || $0.name.lowercased().contains("geforce") || $0.name.lowercased().contains("rtx") }) else {
    print("RTX nao aparece para este processo (lista nvmtl-allow ou RTX parada)"); exit(1)
}
print("usando: \(dev.name)")
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    float a = float(i) * 1e-6f, b = 1.0001f;
    for (int k = 0; k < 4096; k++) { a = fma(a, b, 0.5f); b = fma(b, 0.9999f, 1e-7f); a = sin(a) * cos(b) + a; }
    o[i] = a + b;
}
"""
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let n = 1 << 20
let buf = dev.makeBuffer(length: n * 4, options: .storageModePrivate)!
let q = dev.makeCommandQueue()!
let t0 = Date(); var lotes = 0
while Date().timeIntervalSince(t0) < secs {
    let cb = q.makeCommandBuffer()!; let e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(pso); e.setBuffer(buf, offset: 0, index: 0)
    e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted(); lotes += 1
    if let err = cb.error { print("erro: \(err)"); exit(2) }
    if lotes % 20 == 0 { print(String(format: "%.0f s, %d lotes", Date().timeIntervalSince(t0), lotes)) }
}
print("fim: \(lotes) lotes em \(Int(secs)) s")
