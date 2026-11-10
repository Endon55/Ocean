#define PI 3.1415926
#define GRAVITY 9.81
#define SEED 10
#define TEXTURE_SIZE 256 
#define SPECTRUMS 4
static const int LOG_SIZE = int(log2(TEXTURE_SIZE));
// static const int SIZE = 1024;
static const float Y_GAMMA = 3.3;
static const float _2PI = PI * 2;
static const float WIND_SCALE_COEFFICIENT = .076;


struct OceanData {
    float time;
    float tile_time;
    uint patch_size;
    float ocean_depth;
    uint mesh_size_x;
    uint mesh_size_y;
    uint texture_size;
    float mesh_gap_size;
    float spectrum_texel_size;
    uint displacement_index;
    uint slope_index;
    uint spectrums;
};

struct SpectrumParams
{
    int length_scale[SPECTRUMS]; //Sice of physical ocean this spectrum represents ie. 32x32 meters, vs 256x256 meters.
    float scale[SPECTRUMS]; //Overal scale of the spectrum.
    //1 for nothing, 3.3 for average, and 5+ for storm levels
    float storm_maturity[SPECTRUMS];

	float wind_speed[SPECTRUMS];
    float wind_span[SPECTRUMS]; //How long the distance the wind is blowing for.
    float wind_angle[SPECTRUMS];

    float choppiness[SPECTRUMS]; 

    float wind_spread_control[SPECTRUMS];

    bool initialized[SPECTRUMS];
    float swell; //Waves from old wind ie. wave randomness.
	bool toggle;
    float jacobian_modifier;
};
