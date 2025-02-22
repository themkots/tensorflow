/* Copyright 2021 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

include "mlir/Pass/PassBase.td"

def LinalgTrivialBufferForwarding
    : Pass<"tf-jitrt-linalg-trivial-buffer-forwarding", "mlir::FuncOp"> {
  let summary = "Trivial input to output buffer forwarding for linalg.generic"
                " operations";
  let constructor = "tensorflow::CreateLinalgTrivialBufferForwardingPass()";
  let description = [{
    Trivial pass that reuses input buffers as outputs in linalg.generic
    operations. This pass does not try to do any buffer alias analysis, and
    is intented to work only as a part of TF -> JitRt compilation pipeline. It
    will almost certainly produce invalid IR in any other use case.

    Input buffer forwarding requirements:
      1. Input and output memrefs must have the same shape.
      2. Input and output memrefs should have the same indexing map.
      3. Input and output buffer must be contiguous in memory.
      4. All iterator types must be "parallel".
      5. Input memref deallocated after the linalg.generic operation.

    In this case it is safe to use input memref as an output memref.
  }];
}

def LinalgTrivialCopyRemoval
    : Pass<"tf-jitrt-linalg-trivial-copy-removal", "mlir::FuncOp"> {
  let summary = "Trivial removal of memref.copy operations";
  let constructor = "tensorflow::CreateLinalgTrivialCopyRemovalPass()";
  let description = [{
    A simple pass that replaces patterns of the form

    %1 = memref.alloc() : memref<1x1xf32>
    memref.copy(%0, %1) : memref<1x1xf32>, memref<1x1xf32>
    memref.dealloc %0 : memref<1x1xf32>

    by replacing uses of %1 with %0 and dropping the copy.
  }];
}

def TileCWise : Pass<"tf-jitrt-tile-cwise", "mlir::FuncOp"> {
  let summary = "Tile cwise linalg.generic on tensors.";
  let constructor = "tensorflow::CreateTileCWisePass()";

  let dependentDialects = ["mlir::linalg::LinalgDialect"];

  let options = [
    Option<"cwise_tile_size", "cwise-tile-size",
           "int64_t", /*default=*/"8",
           "Tile size for the innermost dimension of an elementwise op.">,
  ];
}

def TileFill : Pass<"tf-jitrt-tile-fill", "mlir::FuncOp"> {
  let summary = "Tile linalg.fill on tensors";
  let constructor = "tensorflow::CreateTileFillPass()";

  let dependentDialects = ["mlir::linalg::LinalgDialect"];

  let options = [
    Option<"cwise_tile_size", "cwise-tile-size",
           "int64_t", /*default=*/"8",
           "Tile size for the innermost dimension of an elementwise op.">,
  ];
}

def PeelTiledLoops : Pass<"tf-jitrt-peel-tiled-loops", "mlir::FuncOp"> {
  let summary = "Optimize away padding in tiled loops";
  let constructor = "tensorflow::CreatePeelTiledLoopsPass()";
  let dependentDialects = [
    "mlir::linalg::LinalgDialect",
  ];
}

def TileReduction : Pass<"tf-jitrt-tile-reduction", "mlir::FuncOp"> {
  let summary = "Tile and fuse linalg.generic reduction on tensors.";
  let constructor = "tensorflow::CreateTileReductionPass()";
  let dependentDialects = [
    "mlir::linalg::LinalgDialect",
    "mlir::memref::MemRefDialect",
    "mlir::scf::SCFDialect"
  ];

  let description = [{
    Matches linalg.generic to understand whether it is a reduction or not.
    After that performs tiling for vectorization and fusion of producers.
  }];

  let options = [
    Option<"reduction_vector_size", "reduction-vector-size",
           "int64_t", /*default=*/"8", "Vector size.">,
    Option<"reduction_1d_tile_size", "reduction-1d-tile-size",
           "int64_t", /*default=*/"32", "Tile size for a 1D reduction.">,
    ListOption<"reduction_2d_tile_sizes", "reduction-2d-tile-sizes", "int64_t",
               "Tile sizes for a 2D reduction.",
               "llvm::cl::MiscFlags::CommaSeparated">,
  ];
}

def FuseFillIntoTiledReduction
    : Pass<"tf-jitrt-fuse-fill-into-tiled-reduction", "mlir::FuncOp"> {
  let summary = "Fuse `linalg.fill` into `linalg.tiled_loop` with a reduction.";
  let constructor = "tensorflow::CreateFuseFillIntoTiledReductionPass()";
  let dependentDialects = ["mlir::linalg::LinalgDialect"];

  let description = [{
    Fuses `linalg.fill` producers of output tensor arguments into
    `linalg.tiled_loop`.
  }];
}

def Fission : Pass<"tf-jitrt-fission", "mlir::FuncOp"> {
  let summary = "Split _Fused Tensorflow kernels into primitives";
  let constructor = "tensorflow::CreateFissionPass()";
  let dependentDialects = [
    "mlir::TF::TensorFlowDialect"
  ];
}

def Fusion : Pass<"tf-jitrt-fusion", "mlir::FuncOp"> {
  let summary = "Fuse Linalg generic operations on Tensors";
  let constructor = "tensorflow::CreateFusionPass()";
  let description = [{
    Fuse Linalg generic operations on Tensors using custom heuristics for
    producer fusion profitability.
  }];
  let dependentDialects = [
    "mlir::TF::TensorFlowDialect"
  ];
}

def JitRtLegalizeI1Types
    : Pass<"tf-jitrt-legalize-i1-types", "mlir::ModuleOp"> {
  let summary = "Legalize 'i1' tensor types";
  let constructor = "tensorflow::CreateJitRtLegalizeI1TypesPass()";
  let description = [{
    Convert 'i1' tensor types used in any operation into 'i8' tensor types.
  }];
  let dependentDialects = [
    "mlir::TF::TensorFlowDialect",
    "mlir::mhlo::MhloDialect",
  ];
}

def SymbolicShapeOptimization
    : Pass<"tf-jitrt-symbolic-shape-optimization", "mlir::FuncOp"> {
  let summary = "Optimizes broadcasts based on the symbolic shapes";
  let constructor = "tensorflow::CreateSymbolicShapeOptimizationPass()";
  let description = [{
    A simple pass that replaces shape constraints with const witnesses and
    rewrites mhlo.broadcast_in_dim operations with linalg.generic broadcasts
    using the symbolic shape attributes defined on the entrypoint function
    arguments.
  }];
  let dependentDialects = [
    "mlir::mhlo::MhloDialect",
    "mlir::linalg::LinalgDialect"
  ];

  let options = [
   Option<"optimize_only_constraints", "optimize-only-constraints",
          "bool", /*default=*/"false",
          "Optimize only shape constraints and do not touch broadcasts.">,

  ];
}

def Clustering : Pass<"tf-jitrt-clustering", "mlir::FuncOp"> {
  let summary = "Creates `tf_device.cluster` operations according to the TF "
                "JitRt clustering policy";

  let constructor = "tensorflow::CreateTfJitRtClusteringPass()";

  let dependentDialects = ["mlir::tf_device::TensorFlowDeviceDialect"];

  let options = [
   Option<"min_cluster_size", "min-cluster-size", "int" , /*default=*/"1",
          "Do not form clusters smaller of the given size.">,
   // TODO(ezhulenev): This is a temporary workaround to control TF->JitRt
   // clustering policy at runtime.
   ListOption<"oplist", "oplist", "std::string",
               "Explicitly allow operations for clustering. Only operations in "
               "this list will be passed to the TF->JitRt clustering policy. "
               "Alternatively use 'tier1', ..., 'all' to allow clustering for "
               "all operations included in the given clustering tier.",
               "llvm::cl::MiscFlags::CommaSeparated">
  ];
}

def VectorizeTiledOps : Pass<"tf-jitrt-vectorize-tiled-ops", "mlir::FuncOp"> {
  let summary = "Vectorize tiled Linalg ops inside `tiled_loop`";
  let constructor = "tensorflow::CreateVectorizeTiledOpsPass()";
  let dependentDialects = ["mlir::linalg::LinalgDialect"];
}

def TileTranspose : Pass<"tf-jitrt-tile-transpose", "mlir::FuncOp"> {
  let summary = "Tile transpose operations";
  let constructor = "tensorflow::CreateTileTransposePass()";
  let dependentDialects = ["mlir::linalg::LinalgDialect"];
}

def LowerTranspose : Pass<"tf-jitrt-lower-vector-transpose", "mlir::FuncOp"> {
  let summary = "Lower vector transpose operations";
  let constructor = "tensorflow::CreateLowerVectorTransposePass()";
  let dependentDialects = ["mlir::vector::VectorDialect, mlir::LLVM::LLVMDialect"];
}

def RewriteVectorMultiReductionPass :
    Pass<"tf-jitrt-rewrite-vector-multi-reduction", "mlir::FuncOp"> {
  let summary = "Convert `vector.multi_reduction` into `vector.reduction` ops.";
  let constructor = "tensorflow::createRewriteVectorMultiReductionPass()";
  let dependentDialects = ["mlir::memref::MemRefDialect"];
}


def DetensorizeLinalg : Pass<"tf-jitrt-detensorize-linalg", "mlir::FuncOp"> {
  let summary = "Replace 0d tensor inputs to LinalgOp with extracted elements.";
  let constructor = "tensorflow::CreateDetensorizeLinalgPass()";
  let dependentDialects = ["mlir::linalg::LinalgDialect"];
}

def MathApproximation : Pass<"tf-jitrt-math-approximation", "mlir::FuncOp"> {
  let summary = "Approximate math operations with an implementation meant to "
                "match Eigen's results. This is a useful property to have when "
                "comparing results from compiled TF code vs TF1 and TFRT, "
                "which use Eigen. "
                "TODO: evaluate the accuracy of these math approximations vs. "
                "those in upstream MLIR, and merge these upstream if they're "
                "more accurate.";
  let constructor = "tensorflow::CreateMathApproximationPass()";
  let options = [
   ListOption<"oplist", "oplist", "std::string",
              "List of math operations to be approximated. Use 'all' to select "
              "all supported math operations.",
              "llvm::cl::MiscFlags::CommaSeparated">,
  ];
}
