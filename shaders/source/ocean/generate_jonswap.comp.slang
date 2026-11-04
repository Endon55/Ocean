#include "inc_ocean.slang"

#define PI 3.1415926
#define GRAVITY 9.81
#define SEED 10
#define TEXTURE_SIZE 256 
static const int LOG_SIZE = int(log2(TEXTURE_SIZE));
// static const int SIZE = 1024;
static const float Y_GAMMA = 3.3;
static const float g = 9.81;
static const float _2PI = PI * 2;
struct SpectrumParams
{
    bool initialized;
    uint length_scale;
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
static const float CONST_G_PI_HZ = 0.0617096207211472951179130834577942599395883633750017968357;


[[vk_binding(0, 0)]]
Texture2D<float4> images[];
[[vk_binding(1, 0)]]
SamplerState samplers[];

[[vk_binding(0, 1)]]
RWTexture2D<float4> initial_spectrum;
[[vk_binding(1, 1)]]
RWTexture2DArray<float4> spectrum;
[[vk_binding(2, 1)]]
RWTexture2D<float4> displacement;
[[vk_binding(3, 1)]]
ConstantBuffer<OceanData> ocean_data;
[[vk_binding(4, 1)]]
ConstantBuffer<SpectrumParams> params;


//returns a value between 0 and 1
float hash(uint n) {
    // integer hash copied from Hugo Elias
    n = (n << 13U) ^ n;
    n = n * (n * n * 15731U + 0x789221U) + uint(0x1376312589U);
    return float(n & uint(0x7fffffffU)) / float(0x7fffffff);
}

//Rayleigh Distribrution, like a bell curve the left edge is clamped at zero and the right edge can approach infinity.
// takes 2 uniformly random numbers between 0, 1, and outputs 2 numbers on the Rayleigh Distribrution.
float2 gaussian_rand(float rand1, float rand2) {
    rand1 = (max(rand1, .001));
    float R = sqrt(-2.0f * log(rand1));
    float theta = 2.0f * PI * rand2;
    return float2(R * cos(theta), R * sin(theta));
}

float2 EulerFormula(float x) {
    return float2(cos(x), sin(x));
}

float2 complex_mult(float2 a, float2 b) {
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}


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

float directional_spectrum(float wind_angle, float angular_frequency, float angular_frequency_peak, SpectrumParams params) {

    float spread_power = spread_power(angular_frequency, angular_frequency_peak, params.windSpeed);

    float spread = NormalisationFactor(spread_power) * pow(abs(cos(0.5 * wind_angle)), 2 * spread_power);

    return lerp(0.5 / PI, spread, params.wind_spread_control);


}
float spread_power(float angular_frequency, float angular_frequency_peak, float wind_speed) {
    if(angular_frequency > angular_frequency_peak) {
        return 9.77 * pow(abs(angular_frequency / angular_frequency_peak), -2.33 - 1.45 * (wind_speed * angular_frequency_peak / g - 1.17));
    }
    else {
        return 6.97 * pow(abs(angular_frequency / angular_frequency_peak), 4.06);
    }
}

/*
    ω^2 = GRAVITY * wave_number * tanh(wave_number * water_depth)
    this is just a standard equation that ensures the waves a coherent for an ocean.
    The min(20) prevents tanh from exploding and giving bad data.
*/
float calculate_angular_frequency(float wave_number, float water_depth) {
    return sqrt(GRAVITY * wave_number * tanh(min(wave_number * water_depth, 20)));
}

float calculate_angular_derivative(float wave_number, float angular_frequency, float depth) {
    float th = tanh(min(wave_number * depth, 20));
    float ch = cosh(wave_number * depth);
    return GRAVITY * (depth * wave_number / ch / ch + th) / angular_frequency / 2.0f;
}


float jonswap_energy(float angular_frequency, float angular_frequency_peak, float scale_factor, SpectrumParams params) {
    //(g^2/16pi^4) == CONST_G_PI only works for Hz.


    //How this frequency behaves depending on its size
    float sigma = (angular_frequency <= angular_frequency_peak ? 0.07 : 0.09);
    float one_over_frequency = 1.0 / angular_frequency;

    /*
        e^(-1.25 * (frequency / peak_freq)^-4)
        you can flip the divide around to ignore the negative on the exponent
        
        e^(-1.25 * (peak_frequency / freq)^4)
        and we can manually expand the exponent. 

    */
    float peak_over_frequency = angular_frequency_peak / angular_frequency;
    float peak_cutoff = exp(-1.25 * peak_over_frequency * peak_over_frequency * peak_over_frequency * peak_over_frequency);

    /*
       Part that makes the jonswap unique: y^b
       y or gamma or peaking or storm_maturity_factor
       is essentially how violent the waves are, its the secret sauce for the jonswap.
    */
    float peak_distribution = (angular_frequency / angular_frequency_peak) - 1.0;
    float b = exp(-0.5 * (peak_distribution * peak_distribution) / (sigma * sigma));

    return params.scale * scale_factor * GRAVITY * GRAVITY * one_over_frequency * one_over_frequency * one_over_frequency * one_over_frequency * one_over_frequency * peak_cutoff * pow(params.storm_maturity, b) * (3.3 / params.storm_maturity);
}


/*
    Engine assumes a z-up axis convention, reference the engine documentation for specifics
    This ocean will abide that convention.
*/
[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_initial_spectrum(uint3 id: SV_DispatchThreadID)
{
    /*

       We need each waves frequency(λ) to tile perfectly across the whole patch of ocean(in this instance we'll use the texture size)
       to get a perfectly tiling texture as long as we divide the patch size by whole numbers we will get a perfectly tiling texture.
       λ = ocean_size / integer_parameter

       wave_number(k) - how many fit in a standard space (2PI meters).
       as k -> 0 the waves pass slower, it would take many intervals of standard space for a single wave to pass.
       as k -> k_max the waves pass quickly, multiple waves will fit in a standard space.
       k = 2PI / λ
       k = 2PI / (ocean_size / integer_parameter)
       k(integer_param) = (2PI / ocean_size) * integer_parameter
       wave_number_vector(K)
       K(x,y) = k(x), k(y)



       Ok this doesn't work how I thought it did.

       Imagine dropping a rock into a calm pond. A round wave will propegate outwards from that point.
       Now imagine a skipping stone bounding across the water. The waves in front of the rock will have more energy, but there will still be energy that gets sent behind the rock.

       To properly simulate a ring propegating outwards from the center, we want to shift our textures origin from the corner to the center.
       We then use the wave_number, which is just the wavelength of the pixel(xy) we are calculating.

       The wave number, is just how far from the center we are, and we calculate the energy from the wind in the entire circle. 90% of the winds energy is going with the wind direction, but the other 10% will get spread around, the opposite wind direction will be getting .02% of the energy, but it does get some, and that's important for the look of the ocean.

       Now we have a ring of "energy" but what does that mean?
       .^.
       .   ^   .
       ---.----0----.-----
       .   ^   .
       .^.
       ^ wind direction. 
       We don't have infinite resolution to calculate the waves, so instead we break it down to the points of the texture that actually fall on the ring of energy we're calculating.
       Imagine that ring shrinking 1 size smaller, and smaller until it reaches the center, and then 1 larger and larger until it reaches the edge of the texture. We calculate all those rings.

       And with the finite points of the texture we have in the circle, we calculate how it compares to the wind direction and how much energy it should have.

       What effect of this "sampling" circles methodology is that each pixel ends up being it's own wave once the simulation gets going. The fft then combines all the waves together to make 1 coherent ocean.

       Now what do we actually save into the texture?


       First we need to turn the arbitrary energy density of the pixel into an actual sine wave.
       To do that we need to get the size(amplitude) of the wave. We already know its frequency thanks to wave_number. And we can easily derive the wave_number based on texture coordiantes, we never need to save this number.


       amplitude = sqrt((2 * energy * derivative_of_wavenumber / wave_number) * wave_number_delta^2)  

       This gives us perfectly mathamtically uniform waves. Which isn't natural. Some waves will be bigger, some smaller. So to make sure things don't get too crazy we want the numbers to be biased towards 1.0, but with just enough variance to make it interesting and the chance that the scale could be 3.0 but very rarely.

       We will use gaussian random numbers.


       1 wave per pixel in the texture,
       that gives us 4 floats worth of data we can save

       0: The energy in the waves moving with the wind(pretty much all of it)
       1: The energy in the waves moving against the wind(virtually 0)
       2: Wave speed(ω) 
       Those 3 are manditory
       3: 1/kLength, we can save this value instead of recalculating every frame.
     */


    float texture_size = float(ocean_data.texture_size);
    float water_depth = ocean_data.ocean_depth;

    uint seed = id.x + id.y * uint(texture_size) + uint(texture_size);
    seed += SEED;

    float2 half_texture = float2(texture_size * .5, texture_size * .5);
    int2 id2 = id.xy;
    if(id2.x >= half_texture.x) id2.x -= int(texture_size);
    if(id2.y >= half_texture.y) id2.y -= int(texture_size);


    float ocean_patch_size = ocean_data.tile_size;

    float wave_number_delta = (2.0f * PI) / ocean_patch_size;
    //has 2 separate wave numbers inside
    float2 wave_number_vector = id2.xy * wave_number_delta;
    //the compined wave number
    float wave_number = length(wave_number_vector);
    if(wave_number > 0) {
        float water_depth = 10.0;
        float wind_speed = max(params.windSpeed, 0.001f);
        //Converting KM to meter * 1000
        float wind_span = max((params.windSpan * 1000), 1.0f);
        float angular_frequency_peak = 2 * PI * 3.5 * pow((g * g) / (wind_speed * wind_span), 1.0f / 3.0f);

        float scale_factor = params.scale_coefficient * pow((wind_speed * wind_speed) / (g * wind_span), 0.22);

        float angular_frequency = calculate_angular_frequency(wave_number, water_depth);
        float angular_frequency_derivative = calculate_angular_derivative(wave_number, angular_frequency, water_depth);
        //y and x aren't swapped, the function just takes the params backwards.
        float angle = atan2(wave_number_vector.y, wave_number_vector.x);
        float2 gauss_rand1 = gaussian_rand(hash(seed + 1), hash(seed + 2));
        float2 gauss_rand2 = gaussian_rand(hash(seed + 3), hash(seed + 4));
        //Total Energy in the system at this Frequency
        float energy = jonswap_energy(angular_frequency, angular_frequency_peak, scale_factor, params) * directional_spectrum(angle, angular_frequency, angular_frequency_peak, params) * short_wave_fade(wave_number, params);

        float amplitude = sqrt((2 * energy * angular_frequency_derivative / wave_number) * wave_number_delta * wave_number_delta);

//We need both random values to be indepenent, and the way the gauss works is that both numbers it returns are coorelated, thus why we generate 2 sets and only use 1 value from each. 
        //So the random number is choosing a random coordinate in (+x, +y) quadrant and by virtue of not being directly at zero degrees it gives us a random phase offset as well.
        initial_spectrum[id.xy] = float4(float2(gauss_rand2.x, gauss_rand1.y) * amplitude, 0.0, 0.0);
    }
    else {
        initial_spectrum[id.xy] = float4(0.0, 0.0, 0.0, 0.0);
    }
}
[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_packed_spectrum(uint3 id: SV_DispatchThreadID)
{
    //We have the wave components starting position(h0)(xy coords of a clock face)
    //We also need the wave components of the wave directly opposite of this one in the texture. ie, we have x=1, y=1. opposite woud be x=-1, y=-1
    float2 w = initial_spectrum[id.xy].xy;
    float2 w_conj = initial_spectrum[uint2((ocean_data.texture_size - id.x) % ocean_data.texture_size, (ocean_data.texture_size - id.y) % ocean_data.texture_size)].xy;

    /*
        The reason we even need the conjugate is complicated and confusing.
        Every wave has a direct opposite wave with a different amount of energy. ie Wave_A(10, 10) and Wave_B(-10, -10) they don't cancel out because they have different amounts of energy, but they do interact. 
        
        However, we can't guarantee they are in phase with each other. They're both getting advanced through time. We actually need the conjugate wave to move BACKWARDS through time.
        This is just how the math works, don't overthink it. We don't have PHD's

        You might be thinking that we're combining Wave_A with conjugate B, and Wave_B with conjugate A. Then the FFT comes along and merges modified Wave_A with modified Wave_B, this sounds like we're doing the same operation twice and breaking out waves. Apparently not, I don't have a clean answer for this but the fft apparently relies on this assumption.
    */
    initial_spectrum[id.xy] = float4(w, w_conj.x, -w_conj.y);
}



[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_update_spectrum(uint3 id: SV_DispatchThreadID)
{
    //Now we take the initial spectrum, advance it through time to find it's current state. Then derive the complex number pairs for each axis.
    int i = 0;
    float texture_size = float(ocean_data.texture_size);
    float2 half_texture = float2(texture_size * .5, texture_size * .5);

    float4 base_wave = initial_spectrum[id.xy];

    int2 id2 = id.xy;
    if(id2.x >= half_texture.x) id2.x -= int(texture_size);
    if(id2.y >= half_texture.y) id2.y -= int(texture_size);

    float2 w = base_wave.xy;
    float2 w_conj = base_wave.zw;

    float water_depth = ocean_data.ocean_depth;
    float ocean_patch_size = ocean_data.tile_size;

    float wave_number_delta = (2.0f * PI) / ocean_patch_size;
    float2 wave_number_vector = id2.xy * wave_number_delta;
    float wave_number = length(wave_number_vector);
    float wave_number_rcp = rcp(wave_number);
    if(wave_number > 0) {

        // float angular_frequency = calculate_angular_frequency(wave_number, water_depth);
        //Before we were calculating the Exact perfect ocean frequency. But now to make the ocean work in a finite simulation we need to make some slight modifications.
        //Now we calculate the angular_frequency based on a looping time that nudges each vertex a little bit to force it to tile properly.
        float wave_time_delta = 2.0f * PI / ocean_data.tile_time;
        float angular_frequency = floor(sqrt(GRAVITY * wave_number) / wave_time_delta) * wave_time_delta * ocean_data.time;

        float2 exponent = EulerFormula(angular_frequency);
        //Wave at time
        float2 w_t = complex_mult(w, exponent) + complex_mult(w_conj, float2(exponent.x, -exponent.y));

        /* Multiplies the complex number wave_at_time by i.
           Rotates exactly 90⸰ */
        float2 iw_t = float2(-w_t.y, w_t.x);
        //Complex axis number
        float2 cx = iw_t * wave_number_vector.x * wave_number_rcp;
        float2 cy = iw_t * wave_number_vector.y * wave_number_rcp;
        float2 cz = w_t; 
        
        float2 cx_dx = -w_t * wave_number_vector.x * wave_number_vector.x * wave_number_rcp;
        float2 cy_dx = -w_t * wave_number_vector.x * wave_number_vector.y * wave_number_rcp;
        float2 cz_dx = iw_t * wave_number_vector.x;

       float2 cz_dy = iw_t * wave_number_vector.y;
       float2 cy_dy = -w_t * wave_number_vector.y * wave_number_vector.y * wave_number_rcp;

       float2 w_t_cx = float2(cx.x - cy.y, cx.y + cy.x);
       float2 w_t_cy = float2(cz.x - cy_dx.y, cz.y + cy_dx.x);

       float2 w_t_cx_slope = float2(cz_dx.x - cz_dy.y, cz_dx.y + cz_dy.x);
       float2 w_t_cy_slope = float2(cx_dx.x - cy_dy.y, cx_dx.y + cy_dy.x);


        /*
            Right now we have 2 complex numbers, h0, and h0_conj. We need to move those vecotrs through time to the current time.
            To rotate a vector through time we multiply it by Eulers Formula.
            Forward in time:
            e^(i*ϴ) == cosϴ + i*sinϴ
            Backwards in time:
            e^(i*ϴ) == cosϴ - i*sinϴ

            ComplexY = (h0 *(cos(phase) + i * sin(phase)) + h0_conj *(cos(phase) - i * sin(phase)))

            The smart people have an optimized version that we use bellow. 
        */

        spectrum[uint3(id.xy, i * 2)] = float4(w_t_cx, w_t_cy);
        spectrum[uint3(id.xy, i * 2 + 1)] = float4(w_t_cx_slope, w_t_cy_slope);
    }
    else {
        spectrum[uint3(id.xy, i * 2)] = float4(0.0, 0.0, 0.0, 0.0);
        spectrum[uint3(id.xy, i * 2 + 1)] = float4(0.0, 0.0, 0.0, 0.0);
    }
}

//Each ThreadGroup gets one of these.
groupshared float4 fft_buffer[2][TEXTURE_SIZE];

void butterfly_twiddle(uint step, uint index, out uint2 indices, out float2 twiddle) {
    uint b =  TEXTURE_SIZE >> (step + 1);
    uint w = b * (index / b);
    uint i = (w + index) % TEXTURE_SIZE;

    sincos(-_2PI / TEXTURE_SIZE * w, twiddle.y, twiddle.x);

    twiddle.y = -twiddle.y;
    indices = uint2(i, i + b);
}

float4 fft(uint index, float4 input) {
    fft_buffer[0][index] = input;
    GroupMemoryBarrierWithGroupSync();
    uint buffer_index = 0;

    [unroll]
    for(uint step = 0; step < LOG_SIZE; ++step) {
        uint2 inputsIndices;
        float2 twiddle;
        butterfly_twiddle(step, index, inputsIndices, twiddle);

        uint next_buffer_index = buffer_index ^ 1u;
        float4 u = fft_buffer[buffer_index][inputsIndices.x];
        float4 v = fft_buffer[buffer_index][inputsIndices.y];
        fft_buffer[next_buffer_index][index] = u + float4(complex_mult(twiddle, v.xy), complex_mult(twiddle, v.zw));

        buffer_index = next_buffer_index;
        GroupMemoryBarrierWithGroupSync();
    }
    return fft_buffer[buffer_index][index];
}



[shader("compute")]
[numthreads(TEXTURE_SIZE, 1, 1)]
void COMPUTE_horizontal_fft(uint3 id: SV_DispatchThreadID)
{
    for(int i = 0; i < ocean_data.spectrums * 2; ++i)
    {
        spectrum[uint3(id.xy, i)] = fft(id.x, spectrum[uint3(id.xy, i)]);
    }
}
[shader("compute")]
[numthreads(TEXTURE_SIZE, 1, 1)]
void COMPUTE_vertical_fft(uint3 id: SV_DispatchThreadID)
{
    for(int i = 0; i < ocean_data.spectrums * 2; ++i)
    {
        spectrum[uint3(id.yx, i)] = fft(id.x, spectrum[uint3(id.yx, i)]);
    }
}

float4 permute(float4 data, float3 id) {
    return data * (1.0f - 2.0f * ((id.x + id.y) % 2));
}

[shader("compute")]
[numthreads(16, 16, 1)]
void COMPUTE_finalize(uint3 id: SV_DispatchThreadID)
{
    for(int i = 0; i < ocean_data.spectrums; ++i) {

        float4 w_t = spectrum[uint3(id.xy, i * 2)];
        float4 w_t_slope = spectrum[uint3(id.xy, i * 2 + 1)];

        float2 dxdy = w_t.rg;
        float2 dzdxy = w_t.ba;
        float2 dzxdzy = w_t_slope.rg;
        float2 dxxdyy = w_t_slope.ba;

        float3 disp = float3(dxdy.x, dxdy.y, dzdxy.x);

        displacement[id.xy] = float4(disp.xyz, 0.0);
    }
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
