// ----------------------------------------------------------------------------
// Gunrock -- High-Performance Graph Primitives on GPU
// ----------------------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------------------

/**
 * @file vis_enactor.cuh
 * @brief Primitive problem enactor for Vertex-Induced Subgraph
 */

#pragma once

#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/vis/vis_problem.cuh>
#include <gunrock/app/vis/vis_functor.cuh>

namespace gunrock {
namespace app {
namespace vis {

/**
 * @brief Primitive enactor class.
 * @tparam INSTRUMWENT Boolean indicate collect per-CTA clock-count statistics
 */
template<bool INSTRUMENT>
class VISEnactor : public EnactorBase {
 protected:
    /**
     * A pinned, mapped word that the traversal kernels will signal when done
     */
    volatile int *done;
    int          *d_done;
    cudaEvent_t  throttle_event;

    /**
     * @brief Prepare the enactor for kernel call.
     * @param[in] problem Problem object holds both graph and primitive data.
     * \return cudaError_t object indicates the success of all CUDA functions.
     */
    template <typename ProblemData>
    cudaError_t Setup(ProblemData *problem) {
        typedef typename ProblemData::SizeT    SizeT;
        typedef typename ProblemData::VertexId VertexId;

        cudaError_t retval = cudaSuccess;

        // initialize the host-mapped "done"
        if (!done) {
            int flags = cudaHostAllocMapped;

            // allocate pinned memory for done
            if (retval = util::GRError(
                    cudaHostAlloc((void**)&done, sizeof(int) * 1, flags),
                    "Enactor cudaHostAlloc done failed",
                    __FILE__, __LINE__)) return retval;

            // map done into GPU space
            if (retval = util::GRError(
                    cudaHostGetDevicePointer((void**)&d_done, (void*) done, 0),
                    "Enactor cudaHostGetDevicePointer done failed",
                    __FILE__, __LINE__)) return retval;

            // create throttle event
            if (retval = util::GRError(
                    cudaEventCreateWithFlags(&throttle_event, cudaEventDisableTiming),
                    "Enactor cudaEventCreateWithFlags throttle_event failed",
                    __FILE__, __LINE__)) return retval;
        }

        done[0] = -1;

        // graph slice
        typename ProblemData::GraphSlice *graph_slice = problem->graph_slices[0];
        // TODO: uncomment if using data_slice to store primitive-specific array
        //typename ProblemData::DataSlice *data_slice = problem->data_slices[0];

        do {
            // bind row-offsets and bit-mask texture
            cudaChannelFormatDesc row_offsets_desc = cudaCreateChannelDesc<SizeT>();
            oprtr::edge_map_forward::RowOffsetTex<SizeT>::ref.channelDesc = row_offsets_desc;
            if (retval = util::GRError(
                    cudaBindTexture(
                        0,
                        oprtr::edge_map_forward::RowOffsetTex<SizeT>::ref,
                        graph_slice->d_row_offsets,
                        (graph_slice->nodes + 1) * sizeof(SizeT)),
                    "Enactor cudaBindTexture row_offset_tex_ref failed",
                    __FILE__, __LINE__)) break;
        } while (0);
        return retval;
    }

 public:
    /**
     * @brief Constructor
     */
    explicit VISEnactor(bool DEBUG = false) :
        EnactorBase(EDGE_FRONTIERS, DEBUG), done(NULL), d_done(NULL) {}

    /**
     * @brief Destructor
     */
    virtual ~VISEnactor() {
        if (done) {
            util::GRError(cudaFreeHost((void*)done),
                "Enactor FreeHost done failed", __FILE__, __LINE__);
            util::GRError(cudaEventDestroy(throttle_event),
                "Enactor Destroy throttle_event failed", __FILE__, __LINE__);
        }
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Obtain statistics the primitive enacted.
     * @param[out] num_iterations Number of iterations (BSP super-steps).
     */
    template <typename VertexId>
    void GetStatistics(VertexId &num_iterations) {
        cudaThreadSynchronize();
        num_iterations = enactor_stats.iteration;
    }

    /** @} */

    /**
     * @brief Enacts computing on the specified graph.
     *
     * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
     * @tparam FilterKernelPolicy Kernel policy for filter operator.
     * @tparam Problem Problem type.
     *
     * @param[in] context CudaContext pointer for ModernGPU APIs
     * @param[in] problem Problem object.
     * @param[in] max_grid_size Max grid size for kernel calls.
     *
     * \return cudaError_t object indicates the success of all CUDA functions.
     */
    template <
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy,
        typename Problem >
    cudaError_t EnactVIS(
        CudaContext & context,
        Problem     * problem,
        int         max_grid_size = 0) {
        typedef typename Problem::VertexId VertexId;
        typedef typename Problem::Value    Value;
        typedef typename Problem::SizeT    SizeT;

        typedef VISFunctor<VertexId, Value, SizeT, Problem> Functor;

        cudaError_t retval = cudaSuccess;

        do {
            unsigned int *d_scanned_edges = NULL;

            fflush(stdout);

            // lazy initialization
            if (retval = Setup(problem)) break;

            if (retval = EnactorBase::Setup(
                    max_grid_size,
                    AdvanceKernelPolicy::CTA_OCCUPANCY,
                    FilterKernelPolicy::CTA_OCCUPANCY))
                break;

            // single-gpu graph slice and data slice
            typename Problem::GraphSlice *g_slice = problem->graph_slices[0];
            typename Problem::DataSlice *d_slice = problem->d_data_slices[0];

            if (AdvanceKernelPolicy::ADVANCE_MODE == oprtr::advance::LB) {
                if (retval = util::GRError(
                        cudaMalloc((void**)&d_scanned_edges,
                        g_slice->edges * sizeof(unsigned int)),
                        "VISProblem cudaMalloc d_scanned_edges failed",
                        __FILE__, __LINE__)) return retval;
            }

            frontier_attribute.queue_length = g_slice->nodes;
            frontier_attribute.queue_index  = 0;  // work queue index
            frontier_attribute.selector     = 0;
            frontier_attribute.queue_reset  = true;

            // filter: intput all vertices in graph, output selected vertices
            oprtr::filter::Kernel<FilterKernelPolicy, Problem, Functor>
                <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
                enactor_stats.iteration + 1,
                frontier_attribute.queue_reset,
                frontier_attribute.queue_index,
                enactor_stats.num_gpus,
                frontier_attribute.queue_length,
                d_done,
                g_slice->frontier_queues.d_keys[frontier_attribute.selector],
                NULL,
                g_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
                d_slice,
                NULL,
                work_progress,
                g_slice->frontier_elements[frontier_attribute.selector],
                g_slice->frontier_elements[frontier_attribute.selector^1],
                enactor_stats.filter_kernel_stats);

            if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
                "filter::Kernel failed", __FILE__, __LINE__))) break;
            cudaEventQuery(throttle_event);

            frontier_attribute.queue_index++;
            frontier_attribute.selector ^= 1;

            if (retval = work_progress.GetQueueLength(
                    frontier_attribute.queue_index,
                    frontier_attribute.queue_length)) break;
            if (DEBUG) {
                printf("filter queue length: %lld",
                       (long long) frontier_attribute.queue_length);
                util::DisplayDeviceResults(
                    problem->data_slices[0]->d_bitmask, g_slice->nodes);
                printf("input queue for advance:\n");
                util::DisplayDeviceResults(
                    g_slice->frontier_queues.d_keys[frontier_attribute.selector],
                    frontier_attribute.queue_length);
            }

        oprtr::advance::LaunchKernel<AdvanceKernelPolicy, Problem, Functor>(
            NULL,
            enactor_stats,
            frontier_attribute,
            d_slice,
            (VertexId*)NULL,
            (bool*)NULL,
            (bool*)NULL,
            d_scanned_edges,
            g_slice->frontier_queues.d_keys[frontier_attribute.selector],
            g_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
            (VertexId*)NULL,
            (VertexId*)NULL,
            g_slice->d_row_offsets,
            g_slice->d_column_indices,
            (SizeT*)NULL,
            (VertexId*)NULL,
            g_slice->nodes,
            g_slice->edges,
            this->work_progress,
            context,
            gunrock::oprtr::advance::V2V);

        if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
            "advance::Kernel failed", __FILE__, __LINE__))) break;
        cudaEventQuery(throttle_event);

        frontier_attribute.queue_index++;

        if (DEBUG) {
            if (retval = work_progress.GetQueueLength(
                    frontier_attribute.queue_index,
                    frontier_attribute.queue_length)) break;
            printf("advance queue length: %lld",
                   (long long) frontier_attribute.queue_length);
            util::DisplayDeviceResults(
                    g_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
                    frontier_attribute.queue_length);
        }

        // TODO: extract graph with proper format (edge list, csr, etc.)

        if (d_scanned_edges) cudaFree(d_scanned_edges);

        } while (0);

        if (DEBUG) {
            printf("\nGPU Vertex-Induced Subgraph Enact Done.\n");
        }

        return retval;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Primitive enact kernel entry.
     *
     * @tparam Problem Problem type. @see Problem
     *
     * @param[in] context CudaContext pointer for ModernGPU APIs
     * @param[in] problem Pointer to Problem object.
     * @param[in] max_grid_size Max grid size for kernel calls.
     * @param[in] traversal_mode Traversal Mode for advance operator:
     *            Load-balanced or Dynamic cooperative
     *
     * \return cudaError_t object indicates the success of all CUDA functions.
     */
    template <typename Problem>
    cudaError_t Enact(
        CudaContext &context,
        Problem     *problem,
        int         max_grid_size  = 0,
        int         traversal_mode = 0) {
        if (this->cuda_props.device_sm_version >= 300) {
            typedef oprtr::filter::KernelPolicy <
                Problem,             // Problem data type
                300,                 // CUDA_ARCH
                INSTRUMENT,          // INSTRUMENT
                0,                   // SATURATION QUIT
                true,                // DEQUEUE_PROBLEM_SIZE
                8,                   // MIN_CTA_OCCUPANCY
                8,                   // LOG_THREADS
                1,                   // LOG_LOAD_VEC_SIZE
                0,                   // LOG_LOADS_PER_TILE
                5,                   // LOG_RAKING_THREADS
                5,                   // END_BITMASK_CULL
                8 >                  // LOG_SCHEDULE_GRANULARITY
                FilterKernelPolicy;

            typedef oprtr::advance::KernelPolicy <
                Problem,             // Problem data type
                300,                 // CUDA_ARCH
                INSTRUMENT,          // INSTRUMENT
                1,                   // MIN_CTA_OCCUPANCY
                7,                   // LOG_THREADS
                8,                   // LOG_BLOCKS
                32 * 128,            // LIGHT_EDGE_THRESHOLD (used for LB)
                1,                   // LOG_LOAD_VEC_SIZE
                0,                   // LOG_LOADS_PER_TILE
                5,                   // LOG_RAKING_THREADS
                32,                  // WARP_GATHER_THRESHOLD
                128 * 4,             // CTA_GATHER_THRESHOLD
                7,                   // LOG_SCHEDULE_GRANULARITY
                oprtr::advance::TWC_FORWARD >
                ForwardAdvanceKernelPolicy;

            typedef oprtr::advance::KernelPolicy <
                Problem,             // Problem data type
                300,                 // CUDA_ARCH
                INSTRUMENT,          // INSTRUMENT
                1,                   // MIN_CTA_OCCUPANCY
                10,                  // LOG_THREADS
                8,                   // LOG_BLOCKS
                32 * 128,            // LIGHT_EDGE_THRESHOLD (used for LB)
                1,                   // LOG_LOAD_VEC_SIZE
                0,                   // LOG_LOADS_PER_TILE
                5,                   // LOG_RAKING_THREADS
                32,                  // WARP_GATHER_THRESHOLD
                128 * 4,             // CTA_GATHER_THRESHOLD
                7,                   // LOG_SCHEDULE_GRANULARITY
                oprtr::advance::LB >
                LBAdvanceKernelPolicy;

            if (traversal_mode == 0) {
                return EnactVIS<
                    LBAdvanceKernelPolicy, FilterKernelPolicy, Problem>(
                        context, problem, max_grid_size);
            } else {  // traversal_mode == 1
                return EnactVIS<
                    ForwardAdvanceKernelPolicy, FilterKernelPolicy, Problem>(
                        context, problem, max_grid_size);
            }
        }

        // to reduce compile time, get rid of other architecture for now
        // TODO: add all the kernel policy setting for all architectures

        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }

    /** @} */
};

}  // namespace vis
}  // namespace app
}  // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
