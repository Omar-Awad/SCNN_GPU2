#include "Layer.h"

Layer::Layer(const std::string &_network, const std::string &_name, const std::string &_type, bool _ReLU, int _stride,
        int _padding) : ReLU(_ReLU), stride(_stride), padding(_padding) {
    this->network = _network;
    this->name = _name;
    this->type = _type;
}

Layer::~Layer() {
    free(weights);
    free(bias);
    free(activations);
    free(output_activations);
}

float Layer::act_get(int i, int j, int k, int l) const {
    auto index = act_shape[1]*act_shape[2]*act_shape[3]*i + act_shape[2]*act_shape[3]*j + act_shape[3]*k + l;
    return activations[index];
}

float Layer::wgt_get(int i, int j, int k, int l) const {
    auto index = wgt_shape[1]*wgt_shape[2]*wgt_shape[3]*i + wgt_shape[2]*wgt_shape[3]*j + wgt_shape[3]*k + l;
    return weights[index];
}

uint64_t Layer::getMaxIndex(const std::string &array) const {
    if(array == "weights") {
        return wgt_shape[0]*wgt_shape[1]*wgt_shape[2]*wgt_shape[3];
    } else if(array == "bias") {
        return bias_shape[0];
    } else if(array == "activations") {
        return act_shape[0]*act_shape[1]*act_shape[2]*act_shape[3];
    } else if(array == "output_activations") {
        if(out_act_shape.size() == 4) return out_act_shape[0]*out_act_shape[1]*out_act_shape[2]*out_act_shape[3];
        else return out_act_shape[0]*out_act_shape[1];
    } else return 0;
}

void Layer::zero_pad() {

    auto batch_size = act_shape[0];
    auto act_channels = act_shape[1];
    auto Nx = act_shape[2];
    auto Ny = act_shape[3];
    auto new_Nx = Nx + 2*padding;
    auto new_Ny = Ny + 2*padding;

    uint64_t new_max_index = batch_size * act_channels * new_Nx * new_Ny;
    auto tmp_activations = (float *) malloc(new_max_index * sizeof(float));
    if (tmp_activations == nullptr) {
        fprintf(stderr, "Error: Failed to allocate padded activations!\n");
        exit(EXIT_FAILURE);
    }

    for(uint64_t i = 0; i < new_max_index; i++) {
        tmp_activations[i] = 0;
    }

    for(int n = 0; n < batch_size; n++) {
        for (int k = 0; k < act_channels; k++) {
            for (int i = 0; i < Nx; i++) {
                for(int j = 0; j < Ny; j++) {
                    auto index_out = act_channels*new_Nx*new_Ny*n + new_Nx*new_Ny*k + new_Ny*(padding + i) +
                            (padding + j);
                    auto index_in = act_channels*Nx*Ny*n + Nx*Ny*k + Ny*i + j;
                    tmp_activations[index_out] = activations[index_in];
                }
            }
        }
    }

    free(activations);
    activations = tmp_activations;
    act_shape.clear();
    act_shape.push_back(batch_size);
    act_shape.push_back(act_channels);
    act_shape.push_back(new_Nx);
    act_shape.push_back(new_Ny);

}

void Layer::grid_zero_pad(int X, int Y) {

    auto batch_size = act_shape[0];
    auto act_channels = act_shape[1];
    auto Nx = act_shape[2];
    auto Ny = act_shape[3];

    uint64_t new_max_index = batch_size * act_channels * X * Y;
    auto tmp_activations = (float *) malloc(new_max_index * sizeof(float));
    if (tmp_activations == nullptr) {
        fprintf(stderr, "Error: Failed to allocate padded activations!\n");
        exit(EXIT_FAILURE);
    }

    for(uint64_t i = 0; i < new_max_index; i++) {
        tmp_activations[i] = 0;
    }

    for(int n = 0; n < batch_size; n++) {
        for (int k = 0; k < act_channels; k++) {
            for (int i = 0; i < Nx; i++) {
                for(int j = 0; j < Ny; j++) {
                    auto index_out = act_channels*X*Y*n + X*Y*k + Y*i + j;
                    auto index_in = act_channels*Nx*Ny*n + Nx*Ny*k + Ny*i + j;
                    tmp_activations[index_out] = activations[index_in];
                }
            }
        }
    }

    free(activations);
    activations = tmp_activations;
    act_shape.clear();
    act_shape.push_back(batch_size);
    act_shape.push_back(act_channels);
    act_shape.push_back((unsigned)X);
    act_shape.push_back((unsigned)Y);

}

void Layer::act_split_4D(int K, int X, int Y) {

    auto batch_size = act_shape[0];
    auto act_channels = act_shape[1];
    auto Nx = act_shape[2];
    auto Ny = act_shape[3];

    uint64_t new_max_index = batch_size * K * X * Y;
    auto tmp_activations = (float *) malloc(new_max_index * sizeof(float));
    if (tmp_activations == nullptr) {
        fprintf(stderr, "Error: Failed to allocate padded activations!\n");
        exit(EXIT_FAILURE);
    }

    for(int n = 0; n < batch_size; n++) {
        for (int k = 0; k < act_channels; k++) {
            for (int i = 0; i < Nx; i++) {
                for(int j = 0; j < Ny; j++) {
                    auto new_k = k / (X*Y);
                    auto rem = k % (X*Y);
                    auto new_i = rem / Y;
                    auto new_j = rem % Y;
                    auto index_out = K*X*Y*n + X*Y*new_k + Y*new_i + new_j;
                    auto index_in = act_channels*Nx*Ny*n + Nx*Ny*k + Ny*i + j;
                    tmp_activations[index_out] = activations[index_in];
                }
            }
        }
    }

    free(activations);
    activations = tmp_activations;
    act_shape.clear();
    act_shape.push_back(batch_size);
    act_shape.push_back((unsigned)K);
    act_shape.push_back((unsigned)X);
    act_shape.push_back((unsigned)Y);

}

void Layer::wgt_split_4D(int K, int X, int Y) {

    auto num_filters = wgt_shape[0];
    auto wgt_channels = wgt_shape[1];
    auto Kx = wgt_shape[2];
    auto Ky = wgt_shape[3];

    uint64_t new_max_index = num_filters * K * X * Y;
    auto tmp_weights = (float *) malloc(new_max_index * sizeof(float));
    if (tmp_weights == nullptr) {
        fprintf(stderr, "Error: Failed to allocate padded weights!\n");
        exit(EXIT_FAILURE);
    }

    for(int n = 0; n < num_filters; n++) {
        for (int k = 0; k < wgt_channels; k++) {
            for (int i = 0; i < Kx; i++) {
                for(int j = 0; j < Ky; j++) {
                    auto new_k = k / (X*Y);
                    auto rem = k % (X*Y);
                    auto new_i = rem / Y;
                    auto new_j = rem % Y;
                    auto index_out = K*X*Y*n + X*Y*new_k + Y*new_i + new_j;
                    auto index_in = wgt_channels*Kx*Ky*n + Kx*Ky*k + Ky*i + j;
                    tmp_weights[index_out] = weights[index_in];
                }
            }
        }
    }

    free(weights);
    weights = tmp_weights;
    wgt_shape.clear();
    wgt_shape.push_back(num_filters);
    wgt_shape.push_back((unsigned)K);
    wgt_shape.push_back((unsigned)X);
    wgt_shape.push_back((unsigned)Y);

}

void Layer::reshape_to_2D() {

    auto batch_size = act_shape[0];
    auto act_channels = act_shape[1];
    auto Nx = act_shape[2];
    auto Ny = act_shape[3];
    auto new_act_channels = act_channels * Nx * Ny;

    act_shape.clear();
    act_shape.push_back(batch_size);
    act_shape.push_back(new_act_channels);
    act_shape.push_back(1);
    act_shape.push_back(1);

}

// Read network from numpy arrays
void Layer::read_layer() {

    cnpy::NpyArray data_npy;
    uint64_t max_index;

    cnpy::npy_load("net_traces/" + network + "/wgt-" + name + ".npy" , data_npy, wgt_shape);
    max_index = getMaxIndex("weights");
    weights = (float *) malloc(max_index * sizeof(float));
    if (weights == nullptr) {
        fprintf(stderr, "Error: Failed to allocate weights!\n");
        exit(EXIT_FAILURE);
    }
    for(uint32_t i = 0; i < max_index; i++)
        weights[i] = data_npy.data<float>()[i];

    cnpy::npy_load("net_traces/" + network + "/bias-" + name + ".npy" , data_npy, bias_shape);
    max_index = getMaxIndex("bias");
    bias = (float *) malloc(max_index * sizeof(float));
    if (bias == nullptr) {
        fprintf(stderr, "Error: Failed to allocate bias!\n");
        exit(EXIT_FAILURE);
    }
    for(uint32_t i = 0; i < max_index; i++)
        bias[i] = data_npy.data<float>()[i];

    cnpy::npy_load("net_traces/" + network + "/act-" + name + "-0.npy" , data_npy, act_shape);
    max_index = getMaxIndex("activations");
    activations = (float *) malloc(max_index * sizeof(float));
    if (activations == nullptr) {
        fprintf(stderr, "Error: Failed to allocate activations!\n");
        exit(EXIT_FAILURE);
    }
    for(uint32_t i = 0; i < max_index; i++)
        activations[i] = data_npy.data<float>()[i];

    cnpy::npy_load("net_traces/" + network + "/act-" + name + "-0-out.npy" , data_npy, out_act_shape);
    max_index = getMaxIndex("output_activations");
    output_activations = (float *) malloc(max_index * sizeof(float));
    if (output_activations == nullptr) {
        fprintf(stderr, "Error: Failed to allocate output activations!\n");
        exit(EXIT_FAILURE);
    }
    for(uint32_t i = 0; i < max_index; i++)
        output_activations[i] = data_npy.data<float>()[i];

    printf("Layer %s loaded into memory\n",name.c_str());

}