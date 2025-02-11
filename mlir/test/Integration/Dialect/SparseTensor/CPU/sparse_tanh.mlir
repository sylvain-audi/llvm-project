//--------------------------------------------------------------------------------------------------
// WHEN CREATING A NEW TEST, PLEASE JUST COPY & PASTE WITHOUT EDITS.
//
// Set-up that's shared across all tests in this directory. In principle, this
// config could be moved to lit.local.cfg. However, there are downstream users that
//  do not use these LIT config files. Hence why this is kept inline.
//
// DEFINE: %{sparsifier_opts} = enable-runtime-library=true
// DEFINE: %{sparsifier_opts_sve} = enable-arm-sve=true %{sparsifier_opts}
// DEFINE: %{compile} = mlir-opt %s --sparsifier="%{sparsifier_opts}"
// DEFINE: %{compile_sve} = mlir-opt %s --sparsifier="%{sparsifier_opts_sve}"
// DEFINE: %{run_libs} = -shared-libs=%mlir_c_runner_utils,%mlir_runner_utils
// DEFINE: %{run_opts} = -e entry -entry-point-result=void
// DEFINE: %{run} = mlir-cpu-runner %{run_opts} %{run_libs}
// DEFINE: %{run_sve} = %mcr_aarch64_cmd --march=aarch64 --mattr="+sve" %{run_opts} %{run_libs}
//
// DEFINE: %{env} =
//--------------------------------------------------------------------------------------------------

// RUN: %{compile} | %{run} | FileCheck %s
//
// Do the same run, but now with direct IR generation.
// REDEFINE: %{sparsifier_opts} = enable-runtime-library=false
// RUN: %{compile} | %{run} | FileCheck %s
//
// Do the same run, but now with vectorization.
// REDEFINE: %{sparsifier_opts} = enable-runtime-library=false vl=2 reassociate-fp-reductions=true enable-index-optimizations=true
// RUN: %{compile} | %{run} | FileCheck %s
//
// Do the same run, but now with  VLA vectorization.
// RUN: %if mlir_arm_sve_tests %{ %{compile_sve} | %{run_sve} | FileCheck %s %}

// Current fails for SVE, see https://github.com/llvm/llvm-project/issues/60626
// UNSUPPORTED: target=aarch64{{.*}}

#SparseVector = #sparse_tensor.encoding<{ map = (d0) -> (d0 : compressed) }>

#trait_op = {
  indexing_maps = [
    affine_map<(i) -> (i)>   // X (out)
  ],
  iterator_types = ["parallel"],
  doc = "X(i) = OP X(i)"
}

module {
  // Performs zero-preserving math to sparse vector.
  func.func @sparse_tanh(%vec: tensor<?xf64, #SparseVector>)
                       -> tensor<?xf64, #SparseVector> {
    %0 = linalg.generic #trait_op
      outs(%vec: tensor<?xf64, #SparseVector>) {
        ^bb(%x: f64):
          %1 = math.tanh %x : f64
          linalg.yield %1 : f64
    } -> tensor<?xf64, #SparseVector>
    return %0 : tensor<?xf64, #SparseVector>
  }

  // Dumps a sparse vector of type f64.
  func.func @dump_vec_f64(%arg0: tensor<?xf64, #SparseVector>) {
    // Dump the values array to verify only sparse contents are stored.
    %c0 = arith.constant 0 : index
    %d0 = arith.constant -1.0 : f64
    %n = sparse_tensor.number_of_entries %arg0: tensor<?xf64, #SparseVector>
    vector.print %n : index
    %0 = sparse_tensor.values %arg0
      : tensor<?xf64, #SparseVector> to memref<?xf64>
    %1 = vector.transfer_read %0[%c0], %d0: memref<?xf64>, vector<9xf64>
    vector.print %1 : vector<9xf64>
    // Dump the dense vector to verify structure is correct.
    %dv = sparse_tensor.convert %arg0
        : tensor<?xf64, #SparseVector> to tensor<?xf64>
    %3 = vector.transfer_read %dv[%c0], %d0: tensor<?xf64>, vector<32xf64>
    vector.print %3 : vector<32xf64>
    bufferization.dealloc_tensor %dv : tensor<?xf64>
    return
  }

  // Driver method to call and verify vector kernels.
  func.func @entry() {
    // Setup sparse vector.
    %v1 = arith.constant sparse<
       [ [0], [3], [11], [17], [20], [21], [28], [29], [31] ],
         [ -1.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 100.0 ]
    > : tensor<32xf64>
    %sv1 = sparse_tensor.convert %v1
         : tensor<32xf64> to tensor<?xf64, #SparseVector>

    // Call sparse vector kernel.
    %0 = call @sparse_tanh(%sv1) : (tensor<?xf64, #SparseVector>)
                                 -> tensor<?xf64, #SparseVector>

    //
    // Verify the results (within some precision).
    //
    // CHECK:      9
    // CHECK-NEXT: {{( -0.761[0-9]*, 0.761[0-9]*, 0.96[0-9]*, 0.99[0-9]*, 0.99[0-9]*, 0.99[0-9]*, 0.99[0-9]*, 0.99[0-9]*, 1 )}}
    // CHECK-NEXT: {{( -0.761[0-9]*, 0, 0, 0.761[0-9]*, 0, 0, 0, 0, 0, 0, 0, 0.96[0-9]*, 0, 0, 0, 0, 0, 0.99[0-9]*, 0, 0, 0.99[0-9]*, 0.99[0-9]*, 0, 0, 0, 0, 0, 0, 0.99[0-9]*, 0.99[0-9]*, 0, 1 )}}
    //
    call @dump_vec_f64(%0) : (tensor<?xf64, #SparseVector>) -> ()

    // Release the resources.
    bufferization.dealloc_tensor %sv1 : tensor<?xf64, #SparseVector>
    return
  }
}
