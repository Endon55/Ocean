#define PI 3.1415926
#define GRAVITY 9.81
static const float Y_GAMMA = 3.3;
static const float g = 9.81;



struct SpectrumParams
{
	int layer_count;
	float windSpeed;
	float fetch;
    //1 for nothing, 3.3 for average, and 5+ for storm levels
    float storm_maturity;
	float peak_freq;

	float scale;
	float shortWavesFade;
    float alignment; 
    float patch_size;
	bool toggle;

	float extraAlignment;
};
static const float CONST_G_PI = 0.0617096207211472951179130834577942599395883633750017968357;

struct Ocean_Data {
    float time;
    uint mesh_size_x;
    uint mesh_size_y;
    uint texture_size;
    uint spectrum_index;
};

struct Random_Sampler {
    float nums[256];
};
[[vk_binding(0, 0)]]
Texture2D<float4> images[];
[[vk_binding(1, 0)]]
SamplerState samplers[];

[[vk_binding(0, 1)]]
RWTexture2D<float4> image;
[[vk_binding(1, 1)]]
ConstantBuffer<Ocean_Data> ocean_data;
[[vk_binding(2, 1)]]
ConstantBuffer<SpectrumParams> params;
[[vk_binding(3, 1)]]
StructuredBuffer<Random_Sampler> random_sampler;


float compute_peaking(float significant_wave_height, float one_over_peak) {
    float ratio = one_over_peak / sqrt(significant_wave_height);

    if(ratio <= 3.6) {
        return 5.0;
    }else if (ratio > 5.0) {
        return 1.0;
    } else {
        return exp(3.484 - 0.659 * ratio);
    }
}


float jonswap_energy(float frequency, float sigma, SpectrumParams params) {
    //(g^2/16pi^4) == CONST_G_PI
    float one_over_frequency = 1.0 / frequency;

    /*
        e^(-1.25 * (frequency / peak_frequency)^-4)
        you can flip the divide around to ignore the negative on the exponent
        
        e^(-1.25 * (peak_frequency / frequency)^4)
        and we can manually expand the exponent. 
    */
    float peak_over_frequency = params.peak_freq / frequency;
    float peak_cutoff = exp(-1.25 * peak_over_frequency * peak_over_frequency * peak_over_frequency * peak_over_frequency);

    /*
       Part that makes the jonswap unique: y^b
       y or gamma or peaking or storm_maturity_factor
       is essentially how violent the waves are, its the secret sauce for the jonswap.
    */
    float peak_distribution = (frequency / params.peak_freq) - 1.0;
    float b = exp(-0.5 * (peak_distribution * peak_distribution) / (sigma * sigma));

    return params.scale * CONST_G_PI * one_over_frequency * one_over_frequency * one_over_frequency * one_over_frequency * one_over_frequency * peak_cutoff * pow(params.storm_maturity, b);
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID: SV_DispatchThreadID)
{
    float ocean_size = float(ocean_data.mesh_size_x);
    float texture_size = float(ocean_data.texture_size);

    float x = (float(dispatchThreadID.x)/texture_size * ocean_size);
    float z = (float(dispatchThreadID.y)/texture_size * ocean_size);

    float frequency_min = .05;
    float frequency_max = 1;
    float frequency_delta = (frequency_max - frequency_min) / float(params.layer_count);

    float3 displacement = float3(0.0, 0.0, 0.0);

    //Spatial Derivatives
    float dxdx = 0.0;
    float dxdz = 0.0;
    float dzdz = 0.0;

    for (int i = 0; i < params.layer_count; i++) {

        //calculating the total energy in the system for this frequency
        //Frequency(hertz) of this band of energy
        float frequency = frequency_min + float(i) * frequency_delta; 

        //How this frequency behaves depending on its size
        float sigma = (frequency <= params.peak_freq ? 0.07 : 0.09);

        //Total Energy in the system at this Frequency
        float energy = jonswap_energy(frequency, sigma, params);

        //How tall the waves can be given the energy
        float amplitude = sqrt(2.0 * energy * frequency_delta);

        //Represents the speed of a wave at an exact point in time.
        float oscillation_speed = 2.0 * PI * frequency;


        float angle = (float(i) / float(params.layer_count)) * 2 * PI;
        float cos_angle = cos(angle);
        float sin_angle = sin(angle);


        float wave_count = (oscillation_speed * oscillation_speed) / GRAVITY;

        float x_shift = wave_count * cos_angle;
        float z_shift = wave_count * sin_angle;

        float phase = (x_shift * x + z_shift * z + random_sampler[0].nums[i] * 2.0 * PI) - (oscillation_speed * ocean_data.time);

        /*
            When these sin waves add up they can add so much displacement that vertices can go past their neighbor, which results in the peaks of the waves going inside out.

            Rollover is the current amount of rollover, anything greater than 1.0 is a rollover. 
        */
        float rollover_fix_delta = 1.0;

        displacement.x += amplitude * sin(phase) * cos_angle;
        displacement.y += amplitude * cos(phase);
        displacement.z += amplitude * sin(phase) * sin_angle;
    } 
        image[dispatchThreadID.xy] = float4(displacement, 1.0);
}

[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_displacement(uint3 dispatchThreadID: SV_DispatchThreadID)
{

    
}
