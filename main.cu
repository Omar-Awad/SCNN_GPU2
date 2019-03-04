
#include "Layer.h"
#include <cmath>
#include <chrono>

// Constants

/* Number of PE per column */
const int Wt = 8;

/* Number of PE per row */
const int Ht = 8;

/* Column multipliers per PE */
const int I = 4;

/* Row multipliers per PE */
const int F = 4;

//############################################### Read networks ########################################################

std::vector<Layer> read_bvlc_alexnet() {
    std::vector<Layer> network;
    network.emplace_back(Layer("bvlc_alexnet","conv1","conv",true,4,0));
    network.emplace_back(Layer("bvlc_alexnet","conv2","conv",true,1,2));
    network.emplace_back(Layer("bvlc_alexnet","conv3","conv",true,1,1));
    network.emplace_back(Layer("bvlc_alexnet","conv4","conv",true,1,1));
    network.emplace_back(Layer("bvlc_alexnet","conv5","conv",true,1,1));
    network.emplace_back(Layer("bvlc_alexnet","fc6","fc",true,1,0));
    network.emplace_back(Layer("bvlc_alexnet","fc7","fc",true,1,0));
    network.emplace_back(Layer("bvlc_alexnet","fc8","fc",false,1,0));
    return network;
}

//############################################### Auxiliary functions ##################################################

inline
cudaError_t check_error(cudaError_t err, std::string task) {
  if (err != cudaSuccess) {
    fprintf(stderr, "Error: Failed to %s (error code: %s)!\n", task.c_str(), cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
  return err;
}

template <typename T>
T* host2Dev(uint64_t size, const T *h_data, std::string task){
    T* d_data;
    check_error(cudaMalloc((void**) &d_data, size*sizeof(T)),task);
    cudaMemcpy(d_data, h_data, size*sizeof(T), cudaMemcpyHostToDevice);
    return d_data;
}

// Checking function
void check_values(const Layer &layer, const float* output_activations, float min_error = 0.01) {

    printf("Checking values for layer: %s of type %s\n",layer.name.c_str(),layer.type == "conv" ? "convolution" :
            "fully connected");
    uint32_t count = 0;
    for(uint32_t i = 0; i < layer.getMaxIndex("output_activations"); i++) {
        if(fabsf(output_activations[i] - layer.output_activations[i]) > min_error) count++;
    }
    printf("ERRORS: %u out of %lu with absolute error tolerance of %.2f\n\n",count,
            layer.getMaxIndex("output_activations"), min_error);
}

//############################################### CUDA SCNN ############################################################

//naive implementation
__global__ void kAddBias(const int N, const int K, const int W, const int H, const float* d_bias, 
		float* d_output_activations){

    int n = threadIdx.x + blockIdx.x*blockDim.x;
    int k = threadIdx.y + blockIdx.y*blockDim.y;

    if(n < N && k < K){
        for(int w =0; w < W; w++){
            for(int h=0; h<H; h++){
                int pos = n * W * H * K + k * W * H + w * H + h;
                d_output_activations[pos] = d_bias[k];
            }
        }
    }
}

__global__ void kRelu(const int N, const int K, const int W, const int H, float* d_output_activations){
    
    int x = threadIdx.x + blockIdx.x*blockDim.x;

    if(x < N*K*W*H){
    	// Maybe a max with 0 would be faster?
        d_output_activations[x] = (d_output_activations[x] > 0) ? d_output_activations[x] : 0; 
    }
}

//SCNN functions
//naive implmentation
__global__ void kComputePE(int n, int W, int H, int K, int stride, const float* d_act_queue, const int* d_act_queue_x, 
    const int* d_act_queue_y, uint64_t act_queue_size, const float* d_wgt_queue, const int* d_wgt_queue_k,
    const int* d_wgt_queue_r, const int* d_wgt_queue_s, uint64_t wgt_queue_size, float* d_output_activations){
    //TODO: use shared mem.
    //TODO: try different configurations

    int ii = threadIdx.x + blockIdx.x*blockDim.x;
    //int ff = threadIdx.y + blockIdx.y*blockDim.y;

    if(ii < act_queue_size){
        float act = d_act_queue[ii];
        int x = d_act_queue_x[ii];
        int y = d_act_queue_y[ii];
        for(int ff = 0; ff < wgt_queue_size; ff++){
            float wgt = d_wgt_queue[ff];
            float k = d_wgt_queue_k[ff];
            float r = d_wgt_queue_r[ff];
            float s = d_wgt_queue_s[ff];

            //TODO: try to remove div. (takes a lot on GPU)
            int w = (x-r)/stride;
            int h = (y-s)/stride;

             if(w >= 0 && w < W && h >= 0 && h < H) {
                uint32_t pos = n * W * H * K + k * W * H + w * H + h;
                //TODO: memory access not coalesced
                d_output_activations[pos] += act * wgt;
            }
        }
    }
}

//############################################### CPU SCNN #############################################################

void addBias(const int N, const int K, const int W, const int H, const Layer &layer, float* d_output_activations) {

	std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();

	auto bytes = layer.getMaxIndex("bias") * sizeof(float);
	float* d_bias = host2Dev(bytes, layer.bias,"allocate device bias");

    dim3 block(32, 32);
    dim3 grid((N+block.x-1)/block.x,(K+block.y-1)/block.y);
    printf("kAddBias block: (%d,%d,1), grid: (%d,%d,1)\n",block.x,block.y,grid.x,grid.y);
    kAddBias<<<grid, block>>>(N,K,W,H,d_bias,d_output_activations);
    cudaDeviceSynchronize();

    check_error(cudaFree(d_bias),"free device bias");

    std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> time_span = std::chrono::duration_cast<std::chrono::duration<double>>(t2 - t1);

    printf("kAddBias time %.6f\n",time_span.count());
}

void relu(const int N, const int K, const int W, const int H, const Layer &layer, float *d_output_activations) {

	std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
    
    if(layer.ReLU){
        dim3 block(1024, 1);
        dim3 grid((N*K*W*H+block.x-1)/block.x,1);
        kRelu<<<grid,block>>>(N,K,W,H,d_output_activations);
        cudaDeviceSynchronize();
    }

    std::chrono::high_resolution_clock::time_point t2 = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> time_span = std::chrono::duration_cast<std::chrono::duration<double>>(t2 - t1);

    printf("kRelu time %.6f\n",time_span.count());
}

void computePE(int n, int W, int H, int K, int stride, const float* h_act_queue, const int* h_act_queue_x,
        const int* h_act_queue_y, uint64_t act_queue_size, const float* h_wgt_queue, const int* h_wgt_queue_k,
        const int* h_wgt_queue_r, const int* h_wgt_queue_s, uint64_t wgt_queue_size, float* d_output_activations) {

    //TODO: overlap mem. transfer
    float* d_act_queue = host2Dev(act_queue_size, h_act_queue,"allocate device activations queue");
    int* d_act_queue_x = host2Dev(act_queue_size, h_act_queue_x,"allocate device activations queue X dim");
    int* d_act_queue_y = host2Dev(act_queue_size, h_act_queue_y,"allocate device activations queue Y dim");
    float* d_wgt_queue = host2Dev(wgt_queue_size, h_wgt_queue,"allocate device weights queue");
    int* d_wgt_queue_k = host2Dev(wgt_queue_size, h_wgt_queue_k,"allocate device weights queue K filter");
    int* d_wgt_queue_r = host2Dev(wgt_queue_size, h_wgt_queue_r,"allocate device weights queue R dim");
    int* d_wgt_queue_s = host2Dev(wgt_queue_size, h_wgt_queue_s,"allocate device weights queue S dim");

   	// I think that for now we can allocate just once at the begining, since the networks are smaller than 300MB
   	// We can change that in the future though
    //float* d_output_activations;
    //check_error(cudaMalloc((void**) &d_output_activations, N * K * W * H * sizeof(float)),"allocate device output
    //	activations");

    dim3 block(1024, 1);
    dim3 grid((act_queue_size+block.x-1)/block.x,1);

    //TODO: add streams
    kComputePE<<<grid,block>>>(n,W,H,K,stride/2,d_act_queue,d_act_queue_x,d_act_queue_y,act_queue_size,d_wgt_queue,
    	d_wgt_queue_k,d_wgt_queue_r,d_wgt_queue_s,wgt_queue_size,d_output_activations);

    cudaDeviceSynchronize();

    //copy output activations back to host
    //FIX: no need to copy the whole output activations each time
    //cudaMemcpy(h_output_activations, d_output_activations, N * K * W * H * sizeof(float), cudaMemcpyDeviceToHost);

    //free GPU resources
    check_error(cudaFree(d_act_queue),"free device activations queue"); 
    check_error(cudaFree(d_act_queue_x),"free device activations queue X dim"); 
    check_error(cudaFree(d_act_queue_y),"free device activations queue Y dim"); 
    check_error(cudaFree(d_wgt_queue),"free device weights queue"); 
    check_error(cudaFree(d_wgt_queue_k),"free device weights queue K dim"); 
    check_error(cudaFree(d_wgt_queue_r),"free device weights queue R dim"); 
    check_error(cudaFree(d_wgt_queue_s),"free device weights queue S dim");
    //check_error(cudaFree(d_output_activations),"free device output activations");
}

//############################################### Main #################################################################

int main(int argc, char *argv[]) {

    auto network = read_bvlc_alexnet();

    for(auto layer : network) {

        layer.read_layer();

        if(layer.type == "fc") {
            layer.reshape_to_2D();
            auto C = layer.act_shape[1];
            layer.act_split_4D((unsigned)(C / 256), 16, 16);

            auto Ck = layer.wgt_shape[1];
            layer.wgt_split_4D((unsigned)(Ck / 256), 16, 16);
        }

        layer.zero_pad();
        int N = 1; // Force one image, (int) layer.act_shape[0];
        int C = (int) layer.act_shape[1];
        int X = (int) layer.act_shape[2];
        int Y = (int) layer.act_shape[3];

        int K = (int) layer.wgt_shape[0];
        int Ck = (int) layer.wgt_shape[1];
        int R = (int) layer.wgt_shape[2];
        int S = (int) layer.wgt_shape[3];

        int stride = layer.stride;

        int W = (X - R)/stride + 1;
        int H = (Y - S)/stride + 1;

        int groups = C / Ck;
        int Kc = K / groups;
        int kc = 0;

        X = (int)(ceil(X/(double)Wt))*Wt;
        Y = (int)(ceil(Y/(double)Ht))*Ht;
        auto tw = X/Wt;
        auto th = Y/Wt;

        layer.grid_zero_pad(X ,Y);

        uint32_t bytes = N*K*W*H * sizeof(float);

        float* d_output_activations;
        check_error(cudaMalloc((void **) &d_output_activations, bytes),"allocate device output activations");

        addBias(N, K, W, H, layer, d_output_activations);

        // TODO: core compute

        relu(N, K, W, H, layer, d_output_activations);

        auto h_output_activations = (float *) malloc(bytes);
        if (h_output_activations == nullptr) {
            fprintf(stderr, "Error: Failed to allocate output activations!\n");
            exit(EXIT_FAILURE);
        }

        check_error(cudaMemcpy(h_output_activations, d_output_activations, bytes, cudaMemcpyDeviceToHost),
        		"copy output activations from device to host");

        check_values(layer,h_output_activations);
        free(h_output_activations);

        }

		return 0;
}