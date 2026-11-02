#include "inc_ocean.slang"

#define PI 3.1415926
#define GRAVITY 9.81
static const float Y_GAMMA = 3.3;
static const float g = 9.81;
struct SpectrumParams
{
	int layer_count;
    float scale;
    //1 for nothing, 3.3 for average, and 5+ for storm levels
    float storm_maturity;
	float windSpeed;
    float windSpan;
    float choppiness;
	float scale_coefficient;
    float short_wave_fade;
    float wind_spread_control;
    float jacobian_modifier;

	bool toggle;

};
static const float CONST_G_PI = 0.0617096207211472951179130834577942599395883633750017968357;

struct Random_Sampler {
    float nums[256];
};
[[vk_binding(0, 0)]]
Texture2D<float4> images[];
[[vk_binding(1, 0)]]
SamplerState samplers[];

[[vk_binding(0, 1)]]
RWTexture2D<float4> initial_spectrum;
[[vk_binding(1, 1)]]
RWTexture2DArray<float2> spectrum;
[[vk_binding(2, 1)]]
RWTexture2D<float4> displacement;
[[vk_binding(3, 1)]]
ConstantBuffer<OceanData> ocean_data;
[[vk_binding(4, 1)]]
ConstantBuffer<SpectrumParams> params;
[[vk_binding(5, 1)]]
StructuredBuffer<Random_Sampler> random_sampler;



/*
    (a*g^2) / (16 * PI^4)  *  f^-5  * e^(-1.25 * (f / fm)^-4)  * y^b * z
    
    z = (3.3 / y)
    b  = e^((1/(2 * s^2)  *  ((f / fm) - 1)^2)
    fm(peak_frequency Hz) = 3.5 * (g^2 / (U * X)^1/3)

    a(scale)              = is just a global scale parameter 
    f(frequency)          = frequency band we are calculating the total energy for
    y(storm_maturity)     = storm violence/maturity parameter
    s(sigma)              = "spectral width", either .07 or .09 calculated on the fly.
    U(wind_speed)         = wind speed in meters per second m/s
    X(wind_span)          = how much distance the wind had to push on the water
    z(y normalization)    = optional term to normalize the energy so that changing the y parameter doesn't change the total engery in the system.
*/
float short_wave_fade(float wave_number, SpectrumParams params)
{
    return exp(-params.short_wave_fade * params.short_wave_fade * wave_number * wave_number);
}

float directional_spectrum(float wind_angle, float frequency,float peak_freq, SpectrumParams params) {

    float spread_power = spread_power(frequency, peak_freq, params.windSpeed);

    float spread = NormalisationFactor(spread_power) * pow(abs(cos(0.5 * wind_angle)), 2 * spread_power);

    return lerp(0.5 / PI, spread, params.wind_spread_control);


}
float spread_power(float frequency, float peak_freq, float wind_speed) {
    if(frequency > peak_freq) {
        return 9.77 * pow(abs(frequency / peak_freq), -2.33 - 1.45 * (wind_speed * peak_freq / g - 1.17));
    }
    else {
        return 6.97 * pow(abs(frequency / peak_freq), 4.06);
    }

}

float jonswap_energy(float frequency, float sigma, float peak_freq, float scale_factor, SpectrumParams params) {
    //(g^2/16pi^4) == CONST_G_PI
    float one_over_frequency = 1.0 / frequency;

    /*
        e^(-1.25 * (frequency / peak_freq)^-4)
        you can flip the divide around to ignore the negative on the exponent
        
        e^(-1.25 * (peak_frequency / freq)^4)
        and we can manually expand the exponent. 

    */
    float peak_over_frequency = peak_freq / frequency;
    float peak_cutoff = exp(-1.25 * peak_over_frequency * peak_over_frequency * peak_over_frequency * peak_over_frequency);

    /*
       Part that makes the jonswap unique: y^b
       y or gamma or peaking or storm_maturity_factor
       is essentially how violent the waves are, its the secret sauce for the jonswap.
    */
    float peak_distribution = (frequency / peak_freq) - 1.0;
    float b = exp(-0.5 * (peak_distribution * peak_distribution) / (sigma * sigma));

    return params.scale * scale_factor * CONST_G_PI * one_over_frequency * one_over_frequency * one_over_frequency * one_over_frequency * one_over_frequency * peak_cutoff * pow(params.storm_maturity, b) * (3.3 / params.storm_maturity);
}


/*
    Engine assumes a z-up axis convention, reference the engine documentation for specifics
    This ocean will abide that convention.
*/
[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_initialize_spectrum(uint3 id: SV_DispatchThreadID)
{

    //OCEAN IS IN Hz, not angular frequency.

    float texture_size = float(ocean_data.texture_size);

    // float frequency_delta = (frequency_max - frequency_min) / float(params.layer_count);
    float ocean_patch_size = texture_size;
    float2 half_texture = float2(texture_size * .5, texture_size * .5);

    float patch_delta = (2.0f * PI) / ocean_patch_size;
    float2 patch_wave = (id.xy - half_texture) * patch_delta;

    float x = (float(id.x)/texture_size);
    float y = (float(id.y)/texture_size);
    float frequency_min = .05;
    float frequency_max = 1;
    float frequency_delta = (frequency_max - frequency_min) / float(params.layer_count);

    float3 displacement = float3(0.0, 0.0, 0.0);

    float wind_speed = max(params.windSpeed, 0.001f);
    //Converting KM to meter * 1000
    float wind_span = max((params.windSpan * 1000), 1.0f);
    float peak_freq = 3.5 * pow((g * g) / (wind_speed * wind_span), 1.0f / 3.0f);
    
    float scale_factor = params.scale_coefficient * pow((wind_speed * wind_speed) / (g * wind_span), 0.22);

    for (int i = 1; i < texture_size; i++) {
        //calculating the total energy in the system for this frequency
        //Frequency(hertz) of this band of energy
        float frequency = float(i) * frequency_delta; 

        //How this frequency behaves depending on its size
        float sigma = (frequency <= peak_freq ? 0.07 : 0.09);

        //the distance between wave peaks
        float oscillation_speed = 2.0 * PI * frequency;
        float wave_count = (oscillation_speed * oscillation_speed) / GRAVITY;
        //Total Energy in the system at this Frequency
        float energy = jonswap_energy(frequency, sigma, peak_freq, scale_factor, params);

        float angle = (float(i) / float(params.layer_count)) * 2 * PI;
        float cos_angle = cos(angle);
        float sin_angle = sin(angle);
    
        energy *= directional_spectrum(angle, frequency, peak_freq, params) * 2 * PI * short_wave_fade(wave_count, params);
        //How tall the waves can be given the energy
        float amplitude = sqrt(2.0 * energy * frequency_delta);
        //Represents the speed of a wave at an exact point in time.



        float x_shift = wave_count * cos_angle;
        float y_shift = wave_count * sin_angle;

        float phase = (x_shift * x + y_shift * y + random_sampler[0].nums[i] * 2.0 * PI) - (oscillation_speed * ocean_data.time);

        displacement.x += amplitude * sin(phase) * cos_angle;
        displacement.y += amplitude * sin(phase) * sin_angle;
        displacement.z += amplitude * cos(phase);
    } 
        displacement.x *= params.choppiness;
        displacement.y *= params.choppiness;
        initial_spectrum[id.xy] = float4(displacement, 1.0);
}
[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_update_spectrum(uint3 id: SV_DispatchThreadID)
{

}

[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_finalize(uint3 dispatchThreadID: SV_DispatchThreadID)
{



    /*
        Ok we are calculting the Jacobian for this pixel in the texture, to do that
        we use math based on the adjacent pixels in the cardinal directions.

        We will eventually want the texture to tile so the edge might look weird until then.
     */
    uint2 coord = dispatchThreadID.xy;
    //
    // uint2 left_coord = coord; 
    // if(coord.x == 0)
    // {
    //    left_coord.x = ocean_data.texture_size; 
    // }
    // left_coord.x -= 1;
    //
    // uint2 right_coord = coord;
    // right_coord.x += 1;
    // right_coord.x = right_coord.x % ocean_data.texture_size;
    //
    // uint2 up_coord = coord; 
    // if(coord.y == 0)
    // {
    //    up_coord.y = ocean_data.texture_size; 
    // }
    // up_coord.y -= 1;
    //
    // uint2 down_coord = coord;
    // down_coord.y += 1;
    // down_coord.y = down_coord.y % ocean_data.texture_size;
    //
    // float3 left = image[left_coord].xyz;
    // float3 right = image[right_coord].xyz;
    // float3 up = image[up_coord].xyz;
    // float3 down = image[down_coord].xyz;
    //
    // /*
    //     we need to compute how far the 2 pixels currently are from how far they would be in the normal grid.
    //
    //     if the grid is spaced along whole numbers  1,2,3,4,5....  then the space
    //     between numbers is 1.
    //     We get the distance between left and right(and then its the same for up and down) then divide it by the original grid space which is 2 spaces so 2 * 1(the space between numbers)
    //
    //     to minimize divisions i precompute 1/(2 * gap size) and just do 4 multiplies.
    //
    //                    so for the 
    //                    x axis
    //     we calculate the difference between the x and y components
    //                    y axis
    //     we calculate the difference between the x and y components
    //
    //     for simplicity my notation is (axis)(component)
    //
    // */
    //
    // float texel2 = .5;
    // //float texel2 = 1 / (ocean_data.spectrum_texel_size * 2);
    // float xx = (right.x - left.x) * texel2;
    // float xy = (right.y - left.y) * texel2; 
    // float yx = (down.x - up.x) * texel2;
    // float yy = (down.y - up.y) * texel2;
    //
    //
    // /*
    //     now we setup the jacobian matrix
    //     we place each axis into a vertical column.
    //
    //
    //     J = [1 + lambda * xx,     lambda * yx]
    //         [    lambda * xy, 1 + lambda * yy]
    //         I dont really understand why we add 1 yet.
    //
    //     lambda is just a scaling parameter.
    //
    //     The determinant is just a number that tells you how much this matrix
    //     scales stuff.
    //     In this instance we're trying to figure out how much the grid has been scaled already.
    //     the determinant of a 2x2 matrix J
    //     is j11 * j22 - j12 * j21
    //
    // */
    // float lambda = params.jacobian_modifier;
    //
    // float jacobian_determinant = 
    //     (1.0 + lambda * xx) *
    //     (1.0 + lambda * yy) -
    //     (lambda * lambda * xy * yx); 
    //
    displacement[dispatchThreadID.xy] = float4(
    spectrum[uint3(dispatchThreadID.xy, 0)].x,
    spectrum[uint3(dispatchThreadID.xy, 1)].x,
    spectrum[uint3(dispatchThreadID.xy, 2)].x,
    1);
}


float NormalisationFactor(float s)
{
	float s2 = s * s;
	float s3 = s2 * s;
	float s4 = s3 * s;
	if (s < 5)
		return -0.000564 * s4 + 0.00776 * s3 - 0.044 * s2 + 0.192 * s + 0.163;
	else
		return -4.80e-08 * s4 + 1.07e-05 * s3 - 9.53e-04 * s2 + 5.90e-02 * s + 3.93e-01;
}
