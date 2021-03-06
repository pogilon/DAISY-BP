/*

  DAISY Descriptor In Memory
  --------------------------

  A) With TRANSD_FAST_PETAL_PADDING = 0

  DescriptorLength: TOTAL_PETALS_NO * GRADIENTS_NO (so far is 200)
  Data Type: 32-bit float
  Descriptor block of memory: contiguous
  Byte alignment of descriptor start: modulo DescriptorLength * sizeof(float)

  the 'visual' is [DAISY_1_float1,DAISY_1_float2...DAISY_1_float200,
                   DAISY_2_float1,DAISY_2_float2...DAISY_2_float200,
                   ...,...,
                   DAISY_N_float1,DAISY_N_float2...DAISY_N_float200]

  where DAISY floats 1,2,...200 outer dimension is Petals and inner (fast-moving) 
  is gradients (TOTAL_PETALS_NO * GRADIENTS_NO). N = imageWidth * imageHeight

  B) With (Prefix Padding) TRANSD_FAST_PETAL_PADDING > 0

  Inter-descriptor memory: non-contiguous, a gap of 
                           PADDING = TRANSD_FAST_PETAL_PADDING * GRADIENTS_NO
                           which is worth PADDING * sizeof(float) bytes

  Byte alignment of descriptor start: modulo (DescriptorLength + PADDING) * sizeof(float)

  But the actual descriptor data starts at byte; start + PADDING

  The padding is prepended.

  the 'visual' is [PAD_1_float1,PAD_1_float2...,PAD_1_float8,
                   ...,...,
                   PAD_M_float1,PAD_M_float2...,PAD_M_float8,
                   DAISY_1_float1,DAISY_1_float2...DAISY_1_float200,
                   PAD_1_float1,PAD_1_float2...,PAD_1_float8,
                   ...,...,
                   PAD_M_float1,PAD_M_float2...,PAD_M_float8,
                   DAISY_2_float1,DAISY_2_float2...DAISY_2_float200,
                   ...,...,
                   PAD_1_float1,PAD_1_float2...,PAD_1_float8,
                   ...,...,
                   PAD_M_float1,PAD_M_float2...,PAD_M_float8,
                   DAISY_N_float1,DAISY_N_float2...DAISY_N_float200]

  where M = TRANSD_FAST_PETAL_PADDING = usually 0 or 1

  Padding may be needed in order to ensure coalescence of writes 
  during kernel transposeDaisyPairs. Values to test are 0,1,2,3 depending
  on global memory width.

*/

#define CONVX_GROUP_SIZE_X 16
#define CONVX_GROUP_SIZE_Y 8
#define CONVX_WORKER_STEPS 4

kernel void convolve_denx(global   float * massArray,
                            constant float * fltArray,
                            const      int     pddWidth,
                            const      int     pddHeight)
{

  const int lx = get_local_id(0);
  const int ly = get_local_id(1);
  local float lclArray[CONVX_GROUP_SIZE_Y][CONVX_GROUP_SIZE_X * (CONVX_WORKER_STEPS + 2)];

  const int srcOffsetX = (get_group_id(0) * CONVX_WORKER_STEPS-1) * CONVX_GROUP_SIZE_X + lx;
  const int srcOffset = get_global_id(1) * pddWidth + srcOffsetX;

  for(int i = 1; i < CONVX_WORKER_STEPS+1; i++)
    lclArray[ly][i * CONVX_GROUP_SIZE_X + lx] = massArray[srcOffset + i * CONVX_GROUP_SIZE_X];

  lclArray[ly][lx] = (srcOffsetX >= 0 ? massArray[srcOffset]:lclArray[ly][CONVX_GROUP_SIZE_X]);

  lclArray[ly][lx + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X] = (srcOffsetX + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X < pddWidth ? massArray[srcOffset + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X]:lclArray[ly][(CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  for(int w = 1; w < CONVX_WORKER_STEPS+1; w++){
    const int dstOffset = pddWidth * pddHeight + srcOffset;
    float s = 0;

    for(int i = lx-2; i < lx+3; i++)
      s += lclArray[ly][w * CONVX_GROUP_SIZE_X + i] * fltArray[i-lx+2];

    massArray[dstOffset + w * CONVX_GROUP_SIZE_X] = s;
  }
}

#define CONVY_GROUP_SIZE_X 16
#define CONVY_GROUP_SIZE_Y 8
#define CONVY_WORKER_STEPS 4

kernel void convolve_deny(global   float * massArray,
                          constant float * fltArray,
                          const      int     pddWidth,
                          const      int     pddHeight)
{
  const int ly = get_local_id(1);
  const int lx = get_local_id(0);  
  local float lclArray[CONVY_GROUP_SIZE_X][CONVY_GROUP_SIZE_Y * (CONVY_WORKER_STEPS+2) + 1];

  const int srcOffsetY = ((get_group_id(1) * CONVY_WORKER_STEPS-1) * CONVY_GROUP_SIZE_Y + ly);
  const int srcOffset =  srcOffsetY * pddWidth + get_global_id(0) + pddWidth * pddHeight;

  for(int i = 1; i < CONVY_WORKER_STEPS+1; i++)
    lclArray[lx][i * CONVY_GROUP_SIZE_Y + ly] = massArray[srcOffset + i * CONVY_GROUP_SIZE_Y * pddWidth];

  lclArray[lx][ly] = (srcOffsetY >= 0 ? massArray[srcOffset]:lclArray[lx][CONVY_GROUP_SIZE_Y]);

  lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y + ly] = (srcOffsetY + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y < pddHeight ? massArray[srcOffset + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y * pddWidth]:lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  for(int w = 1; w < CONVY_WORKER_STEPS+1; w++){
    const int dstOffset = srcOffset + pddWidth * pddHeight * 7;
    float s = 0;

    for(int i = ly-2; i < ly+3; i++)
      s += lclArray[lx][w * CONVY_GROUP_SIZE_Y + i] * fltArray[i-ly+2];

    massArray[dstOffset + w * CONVY_GROUP_SIZE_Y * pddWidth] = s;
  }
}

kernel void gradients(global float * massArray,
                            const    int     pddWidth,
                            const    int     pddHeight)
{

  const int r = get_global_id(0) / pddWidth;
  const int c = get_global_id(0) % pddWidth;
  const int srcOffset = pddWidth * pddHeight * 8 + r * pddWidth + c;

  float4 n;
  n.x = (c > 0           ? massArray[srcOffset-1]:massArray[srcOffset]);
  n.y = (r > 0           ? massArray[srcOffset-pddWidth]:massArray[srcOffset]);
  n.z = (c < pddWidth-1  ? massArray[srcOffset+1]:massArray[srcOffset]);
  n.w = (r < pddHeight-1 ? massArray[srcOffset+pddWidth]:massArray[srcOffset]);

  float8 gradients;
  const float8 angles = (float8)(0.0f, M_PI / 4, M_PI / 2, 3 * (M_PI / 4), M_PI,
                                  5 * (M_PI / 4), 3 * (M_PI / 2), 7 * (M_PI / 4));
  n.x = (n.z-n.x) * 0.5;
  n.y = (n.w-n.y) * 0.5;

  gradients.s0 = fmax(cos(angles.s0) * n.x + 
                      sin(angles.s0) * n.y, 0.0);
  gradients.s1 = fmax(cos(angles.s1) * n.x + 
                      sin(angles.s1) * n.y, 0.0);
  gradients.s2 = fmax(cos(angles.s2) * n.x + 
                      sin(angles.s2) * n.y, 0.0);
  gradients.s3 = fmax(cos(angles.s3) * n.x + 
                      sin(angles.s3) * n.y, 0.0);
  gradients.s4 = fmax(cos(angles.s4) * n.x + 
                      sin(angles.s4) * n.y, 0.0);
  gradients.s5 = fmax(cos(angles.s5) * n.x + 
                      sin(angles.s5) * n.y, 0.0);
  gradients.s6 = fmax(cos(angles.s6) * n.x + 
                      sin(angles.s6) * n.y, 0.0);
  gradients.s7 = fmax(cos(angles.s7) * n.x + 
                      sin(angles.s7) * n.y, 0.0);

  const int dstOffset = r * pddWidth + c;
  const int push = pddWidth * pddHeight;

  massArray[dstOffset]        = gradients.s0;
  massArray[dstOffset+push]   = gradients.s1;
  massArray[dstOffset+2*push] = gradients.s2;
  massArray[dstOffset+3*push] = gradients.s3;
  massArray[dstOffset+4*push] = gradients.s4;
  massArray[dstOffset+5*push] = gradients.s5;
  massArray[dstOffset+6*push] = gradients.s6;
  massArray[dstOffset+7*push] = gradients.s7;
}

#define CONVX_GROUP_SIZE_X 16
#define CONVX_GROUP_SIZE_Y 4
#define CONVX_WORKER_STEPS 4

kernel void convolve_G0x(global   float * massArray,
                           constant float  * fltArray,
                           const      int     pddWidth,
                           const      int     pddHeight)
{

  const int lx = get_local_id(0);
  const int ly = get_local_id(1);
  local float lclArray[CONVX_GROUP_SIZE_Y][CONVX_GROUP_SIZE_X * (CONVX_WORKER_STEPS + 2)];

  const int srcOffsetX = (get_group_id(0) * CONVX_WORKER_STEPS-1) * CONVX_GROUP_SIZE_X + lx;
  const int srcOffset = get_global_id(1) * pddWidth + srcOffsetX;

  for(int i = 1; i < CONVX_WORKER_STEPS+1; i++)
    lclArray[ly][i * CONVX_GROUP_SIZE_X + lx] = massArray[srcOffset + i * CONVX_GROUP_SIZE_X];

  lclArray[ly][lx] = (srcOffsetX >= 0 ? massArray[srcOffset]:lclArray[ly][CONVX_GROUP_SIZE_X]);

  lclArray[ly][lx + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X] = (srcOffsetX + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X < pddWidth ? massArray[srcOffset + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X]:lclArray[ly][(CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  fltArray += 7;

  for(int w = 1; w < CONVX_WORKER_STEPS+1; w++){
    const int dstOffset = pddWidth * pddHeight * 8 + srcOffset;
    float s = 0;

    for(int i = lx-5; i < lx+6; i++)
      s += lclArray[ly][w * CONVX_GROUP_SIZE_X + i] * fltArray[i-lx+5];

    massArray[dstOffset + w * CONVX_GROUP_SIZE_X] = s;
  }
}

#define CONVY_GROUP_SIZE_Y 8
#define CONVY_WORKER_STEPS 8

kernel void convolve_G0y(global   float * massArray,
                           constant float  * fltArray,
                           const      int     pddWidth,
                           const      int     pddHeight)
{

  const int ly = get_local_id(1);
  const int lx = get_local_id(0);  
  local float lclArray[CONVY_GROUP_SIZE_X][CONVY_GROUP_SIZE_Y * (CONVY_WORKER_STEPS+2) + 1];

  const int srcOffsetY = ((get_group_id(1) * CONVY_WORKER_STEPS-1) * CONVY_GROUP_SIZE_Y + ly);
  const int srcOffset =  srcOffsetY * pddWidth + get_global_id(0) + pddWidth * pddHeight * 8;

  for(int i = 1; i < CONVY_WORKER_STEPS+1; i++)
    lclArray[lx][i * CONVY_GROUP_SIZE_Y + ly] = massArray[srcOffset + i * CONVY_GROUP_SIZE_Y * pddWidth];

  lclArray[lx][ly] = (get_group_id(1) % ((pddHeight / CONVY_WORKER_STEPS) / get_local_size(1)) ? massArray[srcOffset]:lclArray[lx][CONVY_GROUP_SIZE_Y]);

  lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y + ly] = ((srcOffsetY % pddHeight) + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y < pddHeight ? massArray[srcOffset + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y * pddWidth]:lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  fltArray += 7;

  for(int w = 1; w < CONVY_WORKER_STEPS+1; w++){
    const int dstOffset = srcOffset - pddWidth * pddHeight * 8;
    float s = 0;

    for(int i = ly-5; i < ly+6; i++)
      s += lclArray[lx][w * CONVY_GROUP_SIZE_Y + i] * fltArray[i-ly+5];

    massArray[dstOffset + w * CONVY_GROUP_SIZE_Y * pddWidth] = s;
  }
}

#define CONVX_GROUP_SIZE_X 16
#define CONVX_WORKER_STEPS 4

kernel void convolve_G1x(global   float * massArray,
                           constant float  * fltArray,
                           const      int     pddWidth,
                           const      int     pddHeight)
{

  const int lx = get_local_id(0);
  const int ly = get_local_id(1);
  local float lclArray[CONVX_GROUP_SIZE_Y][CONVX_GROUP_SIZE_X * (CONVX_WORKER_STEPS + 2)];

  const int srcOffsetX = (get_group_id(0) * CONVX_WORKER_STEPS-1) * CONVX_GROUP_SIZE_X + lx;
  const int srcOffset = get_global_id(1) * pddWidth + srcOffsetX;

  for(int i = 1; i < CONVX_WORKER_STEPS+1; i++)
    lclArray[ly][i * CONVX_GROUP_SIZE_X + lx] = massArray[srcOffset + i * CONVX_GROUP_SIZE_X];

  lclArray[ly][lx] = (srcOffsetX >= 0 ? massArray[srcOffset]:lclArray[ly][CONVX_GROUP_SIZE_X]);

  lclArray[ly][lx + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X] = (srcOffsetX + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X < pddWidth ? massArray[srcOffset + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X]:lclArray[ly][(CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  fltArray += (7+11);

  for(int w = 1; w < CONVX_WORKER_STEPS+1; w++){
    const int dstOffset = pddWidth * pddHeight * 8 * 2 + srcOffset;
    float s = 0;

    for(int i = lx-11; i < lx+12; i++)
      s += lclArray[ly][w * CONVX_GROUP_SIZE_X + i] * fltArray[i-lx+11];

    massArray[dstOffset + w * CONVX_GROUP_SIZE_X] = s;
  }
}

#define CONVY_GROUP_SIZE_Y 16
#define CONVY_WORKER_STEPS 4

kernel void convolve_G1y(global   float * massArray,
                           constant float  * fltArray,
                           const      int     pddWidth,
                           const      int     pddHeight)
{

  const int ly = get_local_id(1);
  const int lx = get_local_id(0);  
  local float lclArray[CONVY_GROUP_SIZE_X][CONVY_GROUP_SIZE_Y * (CONVY_WORKER_STEPS+2) + 1];

  const int srcOffsetY = ((get_group_id(1) * CONVY_WORKER_STEPS-1) * CONVY_GROUP_SIZE_Y + ly);
  const int srcOffset =  srcOffsetY * pddWidth + get_global_id(0) + pddWidth * pddHeight * 8 * 2;

  for(int i = 1; i < CONVY_WORKER_STEPS+1; i++)
    lclArray[lx][i * CONVY_GROUP_SIZE_Y + ly] = massArray[srcOffset + i * CONVY_GROUP_SIZE_Y * pddWidth];

  lclArray[lx][ly] = (get_group_id(1) % ((pddHeight / CONVY_WORKER_STEPS) / get_local_size(1)) > 0 ? massArray[srcOffset]:lclArray[lx][CONVY_GROUP_SIZE_Y]);

  lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y + ly] = ((srcOffsetY % pddHeight) + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y < pddHeight ? massArray[srcOffset + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y * pddWidth]:lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  fltArray += (7+11);

  for(int w = 1; w < CONVY_WORKER_STEPS+1; w++){
    const int dstOffset = srcOffset - pddWidth * pddHeight * 8;
    float s = 0;

    for(int i = ly-11; i < ly+12; i++)
      s += lclArray[lx][w * CONVY_GROUP_SIZE_Y + i] * fltArray[i-ly+11];

    massArray[dstOffset + w * CONVY_GROUP_SIZE_Y * pddWidth] = s;
  }
}

//#define CONVX_WORKER_STEPS 8

kernel void convolve_G2x(global   float * massArray,
                           constant float  * fltArray,
                           const      int     pddWidth,
                           const      int     pddHeight)
{

  const int lx = get_local_id(0);
  const int ly = get_local_id(1);
  local float lclArray[CONVX_GROUP_SIZE_Y][CONVX_GROUP_SIZE_X * (CONVX_WORKER_STEPS + 2)];

  const int srcOffsetX = (get_group_id(0) * CONVX_WORKER_STEPS-1) * CONVX_GROUP_SIZE_X + lx;
  const int srcOffset = get_global_id(1) * pddWidth + srcOffsetX + pddWidth * pddHeight * 8;

  for(int i = 1; i < CONVX_WORKER_STEPS+1; i++)
    lclArray[ly][i * CONVX_GROUP_SIZE_X + lx] = massArray[srcOffset + i * CONVX_GROUP_SIZE_X];

  lclArray[ly][lx] = (srcOffsetX >= 0 ? massArray[srcOffset]:lclArray[ly][CONVX_GROUP_SIZE_X]);

  lclArray[ly][lx + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X] = (srcOffsetX + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X < pddWidth ? massArray[srcOffset + (CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X]:lclArray[ly][(CONVX_WORKER_STEPS+1) * CONVX_GROUP_SIZE_X-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  fltArray += (7+11+23);

  for(int w = 1; w < CONVX_WORKER_STEPS+1; w++){
    const int dstOffset = pddWidth * pddHeight * 8 * 2 + srcOffset;
    float s = 0;

    for(int i = lx-14+1; i < lx+15-1; i++)
      s += lclArray[ly][w * CONVX_GROUP_SIZE_X + i] * fltArray[i-lx+14-1];

    massArray[dstOffset + w * CONVX_GROUP_SIZE_X] = s;
  }
}

#define CONVY_WORKER_STEPS 4

kernel void convolve_G2y(global   float * massArray,
                           constant float  * fltArray,
                           const      int     pddWidth,
                           const      int     pddHeight)
{

  const int ly = get_local_id(1);
  const int lx = get_local_id(0);
  local float lclArray[CONVY_GROUP_SIZE_X][CONVY_GROUP_SIZE_Y * (CONVY_WORKER_STEPS+2) + 1];

  const int srcOffsetY = ((get_group_id(1) * CONVY_WORKER_STEPS-1) * CONVY_GROUP_SIZE_Y + ly);
  const int srcOffset =  srcOffsetY * pddWidth + get_global_id(0) + pddWidth * pddHeight * 8 * 3;

  for(int i = 1; i < CONVY_WORKER_STEPS+1; i++)
    lclArray[lx][i * CONVY_GROUP_SIZE_Y + ly] = massArray[srcOffset + i * CONVY_GROUP_SIZE_Y * pddWidth];

  lclArray[lx][ly] = (get_group_id(1) % ((pddHeight / CONVY_WORKER_STEPS) / get_local_size(1)) > 0 ? massArray[srcOffset]:lclArray[lx][CONVY_GROUP_SIZE_Y]);

  lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y + ly] = ((srcOffsetY % pddHeight) + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y < pddHeight ? massArray[srcOffset + (CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y * pddWidth]:lclArray[lx][(CONVY_WORKER_STEPS+1) * CONVY_GROUP_SIZE_Y-1]);

  barrier(CLK_LOCAL_MEM_FENCE);

  fltArray += (7+11+23);

  for(int w = 1; w < CONVY_WORKER_STEPS+1; w++){
    const int dstOffset = srcOffset - pddWidth * pddHeight * 8;
    float s = 0;

    for(int i = ly-14+1; i < ly+15-1; i++)
      s += lclArray[lx][w * CONVY_GROUP_SIZE_Y + i] * fltArray[i-ly+14-1];

    massArray[dstOffset + w * CONVY_GROUP_SIZE_Y * pddWidth] = s;
  }
}

#define SMOOTHINGS_NO 3
#define GRADIENTS_NO 8
#define TOTAL_PETALS_NO 25
#define REGION_PETALS_NO 8
#define DESCRIPTOR_LENGTH (TOTAL_PETALS_NO * GRADIENTS_NO)

#define TRANS_GROUP_SIZE_X 32
#define TRANS_GROUP_SIZE_Y 8
kernel void transposeGradients(global float * srcArray,
                               global float * dstArray,
                               const  int     srcWidth,
                               const  int     srcHeight)
{

    const int smoothSectionHeight = srcHeight * GRADIENTS_NO;

    const int smoothSection = get_global_id(1) / smoothSectionHeight;

    const int groupRow = (get_global_id(1) % smoothSectionHeight) / 8;
    const int groupRowGradientSection = get_local_id(1);

    const int srcIndex = (smoothSection * smoothSectionHeight + groupRowGradientSection * srcHeight + groupRow) * srcWidth + get_global_id(0);

    local float lclArray[(TRANS_GROUP_SIZE_X+2) * TRANS_GROUP_SIZE_Y];

    lclArray[get_local_id(1) * (TRANS_GROUP_SIZE_X+2) + get_local_id(0)] = srcArray[srcIndex];

    barrier(CLK_LOCAL_MEM_FENCE);

    const int localY = get_local_id(0) % TRANS_GROUP_SIZE_Y;
    const int localX = get_local_id(0) / TRANS_GROUP_SIZE_Y + get_local_id(1) * (TRANS_GROUP_SIZE_X / TRANS_GROUP_SIZE_Y);

    //
    // Normalisation piggy-backing along with the transposition
    //
    float l2normSum = .0f;
    for(int i = 0; i < GRADIENTS_NO; i++){
      const float g = lclArray[((localY+i) % GRADIENTS_NO) * (TRANS_GROUP_SIZE_X+2) + localX];
      l2normSum += g*g;
    }
    l2normSum = (l2normSum == 0.0 ? 1 : 1 / sqrt(l2normSum));
    //
    //

    const int dstRow = smoothSection * srcHeight + groupRow;
    const int dstCol = get_group_id(0) * TRANS_GROUP_SIZE_X * GRADIENTS_NO + localX * GRADIENTS_NO + localY;

    //dstArray[dstRow * srcWidth * GRADIENTS_NO + dstCol] = dstRow * srcWidth * GRADIENTS_NO + dstCol; // USED FOR INDEX TRACKING
    dstArray[dstRow * srcWidth * GRADIENTS_NO + dstCol] = lclArray[localY * (TRANS_GROUP_SIZE_X+2) + localX] * l2normSum; // this division... the division ALONE... seems to take 10 ms !!!
}

#define TRANSD_BLOCK_WIDTH 512
#define TRANSD_DATA_WIDTH 16
#define TRANSD_PAIRS_OFFSET_WIDTH 1000
#define TRANSD_PAIRS_SINGLE_ONLY -999

kernel void transposeDaisy(global   float * srcArray,
                             global   float * dstArray,
                             constant int   * transArray,
                             local    float * lclArray,
                             const      int     srcWidth,
                             const      int     srcHeight,
                             const      int     srcGlobalOffset,
                             const      int     transArrayLength)
//                             const      int     lclArrayPadding) // either 0 or 8
{

  const int gx = get_global_id(0) - TRANSD_DATA_WIDTH; 
                                   // range across all blocks: [0, srcWidth+2*TRANSD_DATA_WIDTH-1] (pushed back to start from -TRANSD_DATA_WIDTH)
                                   // range for a block:
                                   // (same as for all blocks given that the blocks will now be rectangular --> whole rows)

  const int gy = get_global_id(1) - TRANSD_DATA_WIDTH; 
                                   // range across all blocks: [0, srcHeight+2*TRANSD_DATA_WIDTH-1] (pushed back to start from -TRANSD_DATA_WIDTH)
                                   // range for a block:
                                   // [k * TRANSD_BLOCK_WIDTH,
                                   //  min((k+1) * TRANSD_BLOCK_WIDTH + 2*TRANSD_DATA_WIDTH-1, srcHeight + 2*TRANSD_DATA_WIDTH-1)]

  const int lx = get_local_id(0);
  const int ly = get_local_id(1);

  //local float lclArray[TRANSD_DATA_WIDTH * (TRANSD_DATA_WIDTH * GRADIENTS_NO)];

  // coalesced read (srcGlobalOffset + xid,yid) + padded write to lclArray
  //const int stepsPerWorker = (srcWidth * GRADIENTS_NO) / get_global_size(0); // => globalSizeX must divide 512 (16,32,64,128,256)

  // should be no divergence, whole workgroups take the same path because; 
  // srcWidth and srcHeight must be multiples of TRANSD_DATA_WIDTH = GROUP_SIZE_X = GROUP_SIZE_Y = 16
  if(gx < 0 || gx >= srcWidth || gy < 0 || gy >= srcHeight){
    const int stepsPerWorker = 8;

    for(int i = 0; i < stepsPerWorker; i++){
      lclArray[ly * (TRANSD_DATA_WIDTH * GRADIENTS_NO)      // local Y
                + get_local_size(0) * i + lx] =                               // local X
                                                0;                            // outside border
    }
  }
  else{
    const int stepsPerWorker = 8;

    for(int i = 0; i < stepsPerWorker; i++){
      lclArray[ly * (TRANSD_DATA_WIDTH * GRADIENTS_NO)        // local Y
                + get_local_size(0) * i + lx] =                                 // local X
          srcArray[srcGlobalOffset + gy * srcWidth * GRADIENTS_NO +             // global offset + global Y
            ((gx / get_local_size(0)) * stepsPerWorker + i) * get_local_size(0) // global X
                                               + lx];
    }
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // non-bank-conflicting (at least attempted) read with transArray as well as coalesced write
  const int pairsPerHalfWarp = transArrayLength / ((get_local_size(0) * get_local_size(1)) / 16);
  const int halfWarps = (get_local_size(1) * get_local_size(0)) / 16;
  const int halfWarpId = (ly * get_local_size(0) + lx) / 16;

  const int blockHeight = get_global_size(1) - 2 * TRANSD_DATA_WIDTH;
  const int topLeftY = (get_group_id(1)-1) * TRANSD_DATA_WIDTH;
  const int topLeftX = (get_group_id(0)-1) * TRANSD_DATA_WIDTH;

  //const int dstGroupOffset = (topLeftY * srcWidth + topLeftX) * GRADIENTS_NO * TOTAL_PETALS_NO;
  dstArray += (topLeftY * srcWidth + topLeftX) * GRADIENTS_NO * TOTAL_PETALS_NO;

  const int petalStart = ((srcGlobalOffset / (srcWidth * GRADIENTS_NO)) / srcHeight) * REGION_PETALS_NO + (srcGlobalOffset > 0);

  const int offset = (halfWarpId < (transArrayLength % pairsPerHalfWarp) ? halfWarpId : (transArrayLength % pairsPerHalfWarp));
  for(int p = pairsPerHalfWarp * halfWarpId + offset; 
          p < (halfWarpId == halfWarps-1 ? transArrayLength : pairsPerHalfWarp * (halfWarpId+1) + offset + (halfWarpId < transArrayLength % pairsPerHalfWarp)); 
          p++){
    const int fromP1   = transArray[p * 4];
    const int fromP2   = transArray[p * 4 + 1];
    const int toOffset = transArray[p * 4 + 2];
    const int petalNo  = transArray[p * 4 + 3];
    
    const int toOffsetY = floor(toOffset / (float) TRANSD_PAIRS_OFFSET_WIDTH);
    const int toOffsetX = toOffset - toOffsetY * TRANSD_PAIRS_OFFSET_WIDTH - TRANSD_PAIRS_OFFSET_WIDTH/2;


    if(topLeftY+toOffsetY < 0 || topLeftY+toOffsetY >= blockHeight
    || topLeftX+toOffsetX < 0 || topLeftX+toOffsetX >= srcWidth)
    {     }
    else if(fromP2 != TRANSD_PAIRS_SINGLE_ONLY || (lx < 8)){
      const int intraHalfWarpOffset = (lx >= 8) * (fromP2-fromP1);
      dstArray[(toOffsetY * srcWidth + toOffsetX) * GRADIENTS_NO * TOTAL_PETALS_NO
               + (petalStart + petalNo) * GRADIENTS_NO + lx] =
        lclArray[((fromP1+intraHalfWarpOffset) / TRANSD_DATA_WIDTH) * (TRANSD_DATA_WIDTH * GRADIENTS_NO) 
               + ((fromP1+intraHalfWarpOffset) % TRANSD_DATA_WIDTH) * GRADIENTS_NO + lx % 8];
    }
  }
}

#define TRANSD_FAST_STEPS 4
#define TRANSD_FAST_WG_Y 1
#define TRANSD_FAST_WG_X 128
#define TRANSD_FAST_PETAL_PAIRS 8
#define TRANSD_FAST_PETAL_PADDING 0
//## not robust to WG_Y change
kernel void transposeDaisyPairs(global  float * srcArray,
                                  global  float * dstArray,
                                  const     int     srcWidth,
                                  const     int     srcHeight,
                                  const     int     sectionHeight,
                                  const     int     petalTwoY,
                                  const     int     petalTwoX,      // offset in pixels
                                  const     int     petalOutOffset) // offset in petals = pixels * totalPetals + petalNo
{
  // Y range = blockNo * blockHeight - 15 : (blockNo+1) * blockHeight + 15

  const int lx = get_local_id(0);

  const int sourceY = get_global_id(1) % srcHeight;

  local float lclArray[TRANSD_FAST_WG_Y * TRANSD_FAST_WG_X * TRANSD_FAST_STEPS];

  // fetch 
  if(lx >= TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO){

    if(sourceY + petalTwoY < 0 || sourceY + petalTwoY >= srcHeight){

      for(int k = 0; k < TRANSD_FAST_STEPS; k++)
        lclArray[(k+TRANSD_FAST_STEPS-1) * TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO + lx] = 0;

    }
    else{

      int sourceX = get_group_id(0) * ((TRANSD_FAST_WG_X * TRANSD_FAST_STEPS) / (2 * GRADIENTS_NO)) + 
                    (lx % (TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO)) / GRADIENTS_NO + petalTwoX;

      const int offset = ((get_global_id(1) + petalTwoY) * srcWidth) * GRADIENTS_NO + 
                          lx % GRADIENTS_NO;

      for(int k = 0; k < TRANSD_FAST_STEPS; k++, sourceX += TRANSD_FAST_PETAL_PAIRS){

        lclArray[(k+TRANSD_FAST_STEPS-1) * TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO + lx] = (
          
          (sourceX < 0 || sourceX >= srcWidth) ? 0 : 
           srcArray[offset + sourceX * GRADIENTS_NO]);

      }
    }
  }
  else{

    int sourceX = get_group_id(0) * ((TRANSD_FAST_WG_X * TRANSD_FAST_STEPS) / (2 * GRADIENTS_NO)) + 
                  (lx % (TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO)) / GRADIENTS_NO;

    for(int k = 0; k < TRANSD_FAST_STEPS; k++, sourceX += TRANSD_FAST_PETAL_PAIRS)

      lclArray[k * TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO + lx] = 

          srcArray[(get_global_id(1) * srcWidth + sourceX) * GRADIENTS_NO + lx % GRADIENTS_NO];
  }

  barrier(CLK_LOCAL_MEM_FENCE);

//  const int targetY = sourceY % ((TRANSD_BLOCK_WIDTH * TRANSD_BLOCK_WIDTH) / srcWidth) + 
//                      (petalOutOffset / TOTAL_PETALS_NO) / srcWidth;
  const int blockHeight = ((TRANSD_BLOCK_WIDTH * TRANSD_BLOCK_WIDTH) / srcWidth);

  const int targetY = (sourceY % blockHeight + blockHeight +
                      (petalOutOffset / TOTAL_PETALS_NO) / srcWidth) % blockHeight;

  if(targetY < 0 || targetY >= sectionHeight) return;

  int targetX = get_group_id(0) * ((TRANSD_FAST_WG_X * TRANSD_FAST_STEPS) / (2 * GRADIENTS_NO)) + 
                (petalOutOffset / TOTAL_PETALS_NO) % srcWidth + lx / (GRADIENTS_NO * 2);

  int targetPetalOffset = ((targetY * srcWidth + targetX) * (TOTAL_PETALS_NO + 0) + 
                          abs(petalOutOffset % TOTAL_PETALS_NO) + TRANSD_FAST_PETAL_PADDING) * GRADIENTS_NO;

  int localOffset = (TRANSD_FAST_PETAL_PAIRS * TRANSD_FAST_STEPS * ((lx / GRADIENTS_NO) % 2) + 
                    (lx / GRADIENTS_NO)/2) * GRADIENTS_NO + lx % GRADIENTS_NO;

  for(int k = 0; k < TRANSD_FAST_STEPS; 

          k++,
          targetX += TRANSD_FAST_PETAL_PAIRS, 
          targetPetalOffset += TRANSD_FAST_PETAL_PAIRS * (TOTAL_PETALS_NO + TRANSD_FAST_PETAL_PADDING) * GRADIENTS_NO,
          localOffset += TRANSD_FAST_PETAL_PAIRS * GRADIENTS_NO){

    // kill target petals outside
    if(targetX < 0 || targetX >= srcWidth) continue;

    dstArray[targetPetalOffset + lx % (GRADIENTS_NO * 2)] = lclArray[localOffset];

  }

}

#define TRANSD_FAST_SINGLES_WG_Y 1
#define TRANSD_FAST_SINGLES_WG_X 128
kernel void transposeDaisySingles(global float * srcArray,
                                  global float * dstArray,
                                  const    int     blockHeight)
{ 
  // blockHeight should be the maximum, ie daisyBlockHeight from the .cpp

   // Moves from index range 0-srcWidth to 0-srcWidth*26, filling in petal no 1 out of 0-25
   const int gy = get_global_id(1);
   const int gx = get_global_id(0);
   const int gsx = get_global_size(0);

   // no steps//TRANSD_FAST_PETAL_PADDING) + 
   dstArray[(((gy % blockHeight) * (gsx / GRADIENTS_NO) + gx / GRADIENTS_NO) * 
              (TOTAL_PETALS_NO + TRANSD_FAST_PETAL_PADDING) + 
              TRANSD_FAST_PETAL_PADDING) * GRADIENTS_NO +
              gx % GRADIENTS_NO] = srcArray[gy * gsx + gx];

}

#define WG_FETCHDAISY_X 256
kernel void fetchDaisy(global float * array)
{

  local lclDescriptors[DESCRIPTOR_LENGTH];

  const int daisyNo = get_global_id(0) / WG_FETCHDAISY_X;

  int steps = DESCRIPTOR_LENGTH / WG_FETCHDAISY_X;
  steps = (steps * WG_FETCHDAISY_X < DESCRIPTOR_LENGTH ? steps + 1 : steps);

  const int lx = get_local_id(0);

  // load
  for(int i = 0; i < steps; i++){

    if(i * WG_FETCHDAISY_X + lx >= DESCRIPTOR_LENGTH) break;

    lclDescriptors[i * WG_FETCHDAISY_X + lx] = 

          array[daisyNo * DESCRIPTOR_LENGTH + 
                i * WG_FETCHDAISY_X + lx];

    

  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // store
  for(int i = 0; i < steps; i++){

    if(i * WG_FETCHDAISY_X + lx >= DESCRIPTOR_LENGTH) break;

    array[daisyNo * DESCRIPTOR_LENGTH + 
          i * WG_FETCHDAISY_X + lx] =
              
               lclDescriptors[i * WG_FETCHDAISY_X + lx];

  }

}


/*

  Match layer 3 of a small set of DAISY descriptors (the template)
  to a subsampled set of DAISY descriptors (the target frame)

  Compare for one rotation - use either a different parameterisation or a
  different kernel for each rotation

*/

#define REGION_PETALS_NO 8
#define GRADIENTS_NO 8
#define TOTAL_PETALS_NO 25
#define DESCRIPTOR_LENGTH ((TOTAL_PETALS_NO + TRANSD_FAST_PETAL_PADDING) * GRADIENTS_NO)

#define ROTATIONS_NO 8

#define DC_TMP_PETALS_NO 8
#define DC_TRG_PIXELS_NO 16
#define DC_TRG_PER_LOOP 2
#define DC_WGX 64
#define DC_PX_SPACING 4

#define DIFFSC ((DC_TRG_PER_LOOP * DC_TMP_PETALS_NO * GRADIENTS_NO * ROTATIONS_NO) / DC_WGX)

#define DC_PX_PADDING 1

kernel void diffCoarse( global   float * tmp,
                        global   float * trg,
                        global   float * out,
                        const    int     templateOffset,
                        const    int     width,
                        const    int     regionNo)
{
  local float lclTmp[REGION_PETALS_NO * GRADIENTS_NO];
  local float lclTrg[DC_TRG_PER_LOOP * (REGION_PETALS_NO * GRADIENTS_NO + DC_PX_PADDING)];

  const int lid = get_local_id(0);
  const int gx = get_global_id(0);
  const int gy = get_global_id(1);

  // fetch template pixel
  lclTmp[lid] = tmp[templateOffset * DESCRIPTOR_LENGTH + (TRANSD_FAST_PETAL_PADDING + regionNo * REGION_PETALS_NO + 1) * GRADIENTS_NO + lid];

  int targetStep;
  for(targetStep = 0; targetStep < DC_TRG_PIXELS_NO / DC_TRG_PER_LOOP; targetStep++){

    // fetch target pixels to local memory; GRADIENTS_NO x REGION_PETALS_NO x TRG_PER_LOOP
    int i;
    for(i = 0; i < DC_TRG_PER_LOOP; i++){

      lclTrg[i * (DC_WGX+DC_PX_PADDING) + lid] = 

        trg[((gy * DC_PX_SPACING + max((DC_PX_SPACING / 2 -1),0)) * width + ((gx / DC_WGX) * DC_TRG_PIXELS_NO + targetStep * DC_TRG_PER_LOOP + i) * 
             DC_PX_SPACING + max((DC_PX_SPACING / 2 -1),0)) * DESCRIPTOR_LENGTH +
             (TRANSD_FAST_PETAL_PADDING + regionNo * REGION_PETALS_NO + 1) * GRADIENTS_NO + lid];

    }

    barrier(CLK_LOCAL_MEM_FENCE);

    // do 4 diffs and sum them
    float diffs = 0.0;
    
    for(i = 0; i < DIFFSC; i++){

      // first 32 threads do diffs for the first pixel, others for the second pixel
      // first 4 threads do diffs for rotation 0, next 4 threads rotation 1....
      const int pixelNo = lid / (DC_WGX / DC_TRG_PER_LOOP);
      const int rotationNo = (lid / (DC_WGX / (DC_TRG_PER_LOOP * ROTATIONS_NO))) % ROTATIONS_NO; 

      const int petalNo = (lid % 4) * 2; // first template petal

      // get these by rotationNo and lid
      const int trgPetal = (petalNo + rotationNo) % REGION_PETALS_NO;
      const int trgFirstGradient = rotationNo;

      // pick pixel, pick rotation => pick petal, pick gradient
      diffs += fabs(lclTmp[petalNo * GRADIENTS_NO + i] - 
                    lclTrg[pixelNo * (REGION_PETALS_NO * GRADIENTS_NO + DC_PX_PADDING) + 
                           ((trgPetal + i / GRADIENTS_NO) % REGION_PETALS_NO) * GRADIENTS_NO + 
                            (trgFirstGradient + i) % GRADIENTS_NO]);

    }

    barrier(CLK_LOCAL_MEM_FENCE);

    // put them in local memory
    lclTrg[lid] = diffs;

    barrier(CLK_LOCAL_MEM_FENCE);

    // the first 32 threads sum half of the 64 values
    if(lid < DC_WGX / 2)
      lclTrg[lid * 2] = lclTrg[lid * 2] + 
                        lclTrg[lid * 2 + 1];


    // the first 16 threads sum the half of half
    if(lid < DC_WGX / 4){

      diffs = lclTrg[lid * 4] + lclTrg[lid * 4 + 2];

      // first 16 fetch and write to global
      out[(gy * (width / DC_PX_SPACING) + gx / (DC_WGX / DC_TRG_PIXELS_NO) + targetStep * DC_TRG_PER_LOOP) * 
              ROTATIONS_NO + lid] = 

          (regionNo < 2 ? 

              out[(gy * (width / DC_PX_SPACING) + gx / (DC_WGX / DC_TRG_PIXELS_NO) + targetStep * DC_TRG_PER_LOOP) * ROTATIONS_NO + lid]
                
                  : 0) + diffs;

    

    }

    barrier(CLK_LOCAL_MEM_FENCE);

  }

}

#define WGX_TRANSPOSE_ROTATIONS 128
#define SEGMENT_SIZE (WGX_TRANSPOSE_ROTATIONS / ROTATIONS_NO)
kernel void transposeRotations(global float * in,
                               global float * out,
                               const  int     height,
                               const  int     width)
{

  local float lcl[WGX_TRANSPOSE_ROTATIONS];
  const int lid = get_local_id(0);
  const int gy = get_global_id(1);
  const int gx = get_global_id(0);

  lcl[lid] = in[gy * width * ROTATIONS_NO + gx];
  
  barrier(CLK_LOCAL_MEM_FENCE);

  // will have 32 threads per target rotation
  const int rotation = lid / SEGMENT_SIZE;

  out[rotation * height * width + gy * width + 
      get_group_id(0) * SEGMENT_SIZE + gx % SEGMENT_SIZE] = 

      lcl[rotation + (lid % SEGMENT_SIZE) * ROTATIONS_NO];

}

#define WGX_REDUCEMIN 256

kernel void reduceMin(global float * in,
                      global float * out,
                      const  int     size,
                      local  volatile float * lcl){

    // perform first level of reduction,
    // reading from global memory, writing to shared memory
    const int lid = get_local_id(0);
    const int i = get_group_id(0) * (get_local_size(0) * 1) + lid;

    short int isLess;
    if(i < size){
      lcl[lid] = in[get_global_id(0)];
    }
    else{ lcl[lid] = 999; return; }

    barrier(CLK_LOCAL_MEM_FENCE);

    if(lid < 128){

      isLess = isless(lcl[lid], lcl[lid + 128]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 128]);
      lcl[lid + 128] = (isLess ? lid : lid + 128);

    }

    barrier(CLK_LOCAL_MEM_FENCE); 

    if(lid < 64) {

      isLess = isless(lcl[lid],lcl[lid + 64]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 64]);
      lcl[lid + 64] = (isLess ? lcl[lid + 128] : lcl[lid + 64 + 128]);

    }
    barrier(CLK_LOCAL_MEM_FENCE); 
    
    if (lid < 32)
    {
        // Might need to end threads after each step...

        // Assuming WGX_REDUCEMIN >= 128
        isLess = isless(lcl[lid], lcl[lid + 32]);
        lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 32]);
        lcl[lid + 32] = (isLess ? lcl[lid + 64] : lcl[lid + 32 + 64]);

        if(lid < 16){
          // Assuming WGX_REDUCEMIN >= 64
          isLess = isless(lcl[lid], lcl[lid + 16]);
          lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 16]);
          lcl[lid + 16] = (isLess ? lcl[lid + 32] : lcl[lid + 16 + 32]);
        }

        if(lid < 8){
          // Assuming WGX_REDUCEMIN >= 32
          isLess = isless(lcl[lid], lcl[lid + 8]);
          lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 8]);
          lcl[lid + 8] = (isLess ? lcl[lid + 16] : lcl[lid + 8 + 16]);
        }

        if(lid < 4){
          // Assuming WGX_REDUCEMIN >= 16
          isLess = isless(lcl[lid], lcl[lid + 4]);
          lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 4]);
          lcl[lid + 4] = (isLess ? lcl[lid + 8] : lcl[lid + 4 + 8]);
        }

        if(lid < 2){
          // Assuming WGX_REDUCEMIN >= 8
          isLess = isless(lcl[lid], lcl[lid + 2]);
          lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 2]);
          lcl[lid + 2] = (isLess ? lcl[lid + 4] : lcl[lid + 2 + 4]);
        }

        if(lid < 1){
          // Assuming WGX_REDUCEMIN >= 4
          isLess = isless(lcl[lid], lcl[lid + 1]);
          lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 1]);
          lcl[lid + 1] = (isLess ? lcl[lid + 2] : lcl[lid + 1 + 2]);
        }

    }
    
    const int groups = get_num_groups(0);
    const int wgid = get_group_id(0);
    const int dstOffset = (get_global_offset(0) / size) * groups;

    // write result for this block to global mem 
    if(lid == 0) out[dstOffset + wgid] = get_global_offset(0) + (i - lid) + lcl[1];

}

//
// Reduce the minima given by the workgroups of reduceMin but for all rotations
//
//#define WGX_REDUCEMINALL = minimaPerRotation = (coarseHeight*coarseWidth / WGX_REDUCEMIN)
kernel void reduceMinAll(global float * in,
                         global float * mid,
                         global float * out,
                         const  int     minimaPerRotation,
                         local  float * lcl,
                         const  int     outStride){
  
    short int isLess;
    const int wgid = get_group_id(0); // rotationNo
    const int lid = get_local_id(0);

    lcl[lid] = (lid < minimaPerRotation ? in[(int)(mid[wgid * minimaPerRotation + lid])] : 999);

    barrier(CLK_LOCAL_MEM_FENCE); 

    // If the number of minima is less than the workgroup size
    if(lid >= minimaPerRotation) return;

    if(lid < 32){
      // Assuming WGX_REDUCEMIN >= 128
      isLess = isless(lcl[lid], lcl[lid + 32]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 32]);
      lcl[lid + 32] = (isLess ? mid[wgid * minimaPerRotation + lid] : mid[wgid * minimaPerRotation + lid + 32]);
    }

    if(lid < 16){
      // Assuming WGX_REDUCEMIN >= 64
      isLess = isless(lcl[lid], lcl[lid + 16]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 16]);
      lcl[lid + 16] = (isLess ? lcl[lid + 32] : lcl[lid + 16 + 32]);
    }

    if(lid < 8){
      // Assuming WGX_REDUCEMIN >= 32
      isLess = isless(lcl[lid], lcl[lid + 8]);
      lcl[lid] = min(lcl[lid], lcl[lid + 8]);
      lcl[lid + 8] = (isLess ? lcl[lid + 16] : lcl[lid + 8 + 16]);
    }

    if(lid < 4){
      // Assuming WGX_REDUCEMIN >= 16
      isLess = isless(lcl[lid], lcl[lid + 4]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 4]);
      lcl[lid + 4] = (isLess ? lcl[lid + 8] : lcl[lid + 4 + 8]);
    }

    if(lid < 2){
      // Assuming WGX_REDUCEMIN >= 8
      isLess = isless(lcl[lid], lcl[lid + 2]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 2]);
      lcl[lid + 2] = (isLess ? lcl[lid + 4] : lcl[lid + 2 + 4]);
    }

    if(lid < 1){
      // Assuming WGX_REDUCEMIN >= 4
      isLess = isless(lcl[lid], lcl[lid + 1]);
      lcl[lid] = (isLess ? lcl[lid] : lcl[lid + 1]);
      lcl[lid + 1] = (isLess ? lcl[lid + 2] : lcl[lid + 1 + 2]);
    }

    if(lid == 0) {
      out[wgid * outStride + get_global_offset(0)] = ((int)lcl[1]) % (minimaPerRotation * WGX_REDUCEMIN);
      out[(wgid + ROTATIONS_NO) * outStride + get_global_offset(0)] = lcl[0];
    }

}

kernel void normaliseRotation(global float * data,
                              global float * maxima){

  data[get_global_id(0)] /= maxima[get_global_offset(0) / get_global_size(0)];

}

//
// Middle Layer - Large Number of Template Points
//
// Compile-Time Arguments
//
// --- Tuning ---
//#define DM_WGX
//#define WG_TARGETS_NO
//#define TARGETS_PER_LOOP
//
// GTX660 OPTIMAL: WGX = 128, WG_TARGETS_NO = 64, TARGETS_PER_LOOP = 8
//
// --- Layer Parameterisation ---
//#define SEARCH_WIDTH
//#define DM_ROTATIONS_NO
//


#define DM_PIXEL_SPACING 1

#define DM_WORKERS_PER_TEMPLATE ((DM_SEARCH_WIDTH * DM_SEARCH_WIDTH) / DM_WG_TARGETS_NO) * DM_WGX

#define DM_IMPORTS_PER_WG (DM_WGX / (REGION_PETALS_NO * GRADIENTS_NO))

#define DM_DIFFS (DM_TARGETS_PER_LOOP * REGION_PETALS_NO * GRADIENTS_NO * DM_ROTATIONS_NO) / DM_WGX
#define DM_OUTPUT (DM_TARGETS_PER_LOOP * DM_ROTATIONS_NO)

#define DM_LCL_PADDING 2

// tmp - get template descriptors from
// trg - get target descriptors from
// diff - store differences
// corrs - get template coord and target coord using template index 0-(TEMPLATE_POINTS_NO-1)
kernel void diffMiddle( global   float * tmp,
                        global   float * trg,
                        global   float * diff,
                        global   float * corrs,
                        const    int     width,
                        local    float * lclTrg,
                        const    int     regionNo,
                        const    int     startRotationNo, 
                        const    int     templateNoOffset)
{

  local float lclTmp[REGION_PETALS_NO * GRADIENTS_NO + 1];
//  local float lclTrg[TARGETS_PER_LOOP * (REGION_PETALS_NO * GRADIENTS_NO + DM_LCL_PADDING)];

  const int lx = get_local_id(0);

  // get template pixel no
  const int templateNo = templateNoOffset + get_global_id(1);
  const int searchNo = (get_global_id(0) / DM_WGX) * DM_WG_TARGETS_NO;
  const int searchOffset = (((searchNo / DM_SEARCH_WIDTH) - DM_SEARCH_WIDTH / 2) * width 
                         + ((searchNo % DM_SEARCH_WIDTH) - DM_SEARCH_WIDTH / 2)) * DM_PIXEL_SPACING;

  const int targetOffset = (int)corrs[templateNo * 2 + 1] + searchOffset;

  const int rotNo = ((lx * (DM_TARGETS_PER_LOOP * DM_ROTATIONS_NO)) / DM_WGX) % DM_ROTATIONS_NO;

  // fetch template pixel
  if(lx < 64){
    lclTmp[lx] = tmp[((int)corrs[templateNo * 2]) * DESCRIPTOR_LENGTH + (TRANSD_FAST_PETAL_PADDING + regionNo * REGION_PETALS_NO + 1) * GRADIENTS_NO + lx];
//    if(DM_WGX == 32)
//      lclTmp[lx+32] = tmp[((int)corrs[templateNo * 2]) * DESCRIPTOR_LENGTH + (regionNo * REGION_PETALS_NO + 1) * GRADIENTS_NO + lx + 32];
  }

  const int pixelSpacing = (regionNo == 2 ? 2 : 1);

  int targetStep;
  for(targetStep = 0; targetStep < (DM_WG_TARGETS_NO / DM_TARGETS_PER_LOOP); targetStep++){

    int i;
    // fetch TARGETS_PER_LOOP target pixels to lclTrg; GRADIENTS_NO x REGION_PETALS_NO x TARGETS_PER_LOOP
    for(i = 0; i < DM_TARGETS_PER_LOOP / (pixelSpacing * DM_IMPORTS_PER_WG); i++){

        const int pxNo = (targetStep * (DM_TARGETS_PER_LOOP / pixelSpacing) + i * DM_IMPORTS_PER_WG
                             + lx / (REGION_PETALS_NO * GRADIENTS_NO)) * pixelSpacing;

        lclTrg[i * (DM_WGX + DM_LCL_PADDING * DM_IMPORTS_PER_WG) +
                (lx / (REGION_PETALS_NO * GRADIENTS_NO)) * DM_LCL_PADDING + lx] =  


            trg[targetOffset * DESCRIPTOR_LENGTH +

             + ((pxNo / DM_SEARCH_WIDTH) * width + pxNo % DM_SEARCH_WIDTH) * DESCRIPTOR_LENGTH 

             + (TRANSD_FAST_PETAL_PADDING + regionNo * REGION_PETALS_NO + 1) * GRADIENTS_NO + lx % (REGION_PETALS_NO * GRADIENTS_NO)];

    }

    barrier(CLK_LOCAL_MEM_FENCE);

    // do 4 rotation diffs
    float diffs = 0.0;
    const int pixelNo = ((lx * DM_TARGETS_PER_LOOP) / DM_WGX) / pixelSpacing;
    const int rotationNo = (startRotationNo + rotNo) % ROTATIONS_NO;

    for(i = 0; i < DM_DIFFS; i++){


      // IF WORKERS PER PETAL CHANGE THEN CHANGE THIS
#if DM_DIFFS == 1
      const int petalNo = (lx / 8) % REGION_PETALS_NO;  // for 64 workers per rotation
#elif DM_DIFFS == 2
      const int petalNo = (lx / 4) % REGION_PETALS_NO;  // for 32 workers per rotation
#elif DM_DIFFS == 4
      const int petalNo = (lx / 2) % REGION_PETALS_NO;  // for 16 workers per rotation
#elif DM_DIFFS == 8
      const int petalNo = lx % REGION_PETALS_NO;        // for 8 workers per rotation
#elif DM_DIFFS == 16
      const int petalNo = (lx % 4) * 2;                 // for 4 workers per rotation
#elif DM_DIFFS == 32
      const int petalNo = (lx % 2) * 4;                 // for 2 workers per rotation
#elif DM_DIFFS == 64
      const int petalNo = 0;                            // for 1 worker per rotation
#endif

      // get these by rotationNo and lid
      const int trgPetal = (petalNo + rotationNo) % REGION_PETALS_NO;
      const int trgFirstGradient = rotationNo;

      // pick pixel, pick rotation => pick petal, pick gradient
      diffs += fabs(lclTmp[petalNo * GRADIENTS_NO + i] -                                  // (petalNo / 4) is padding that speeds up by 1ms

                    lclTrg[pixelNo * (REGION_PETALS_NO * GRADIENTS_NO + DM_LCL_PADDING) +    // the +1 is padding that speeds up by 1ms

                            ((trgPetal + i / GRADIENTS_NO) % REGION_PETALS_NO) * GRADIENTS_NO + 

                            (trgFirstGradient + i) % GRADIENTS_NO]);

    }

    barrier(CLK_LOCAL_MEM_FENCE);

    //
    // put them in local memory
    lclTrg[lx] = diffs;

#if DM_OUTPUT <= (DM_WGX / 2)

    barrier(CLK_LOCAL_MEM_FENCE);

    // the first 32 threads sum 64 to 32
    if(lx < DM_WGX / 2){

      lclTrg[lx * 2] = lclTrg[lx * 2] + 
                       lclTrg[lx * 2 + 1];

    }

#endif

#if DM_OUTPUT <= (DM_WGX / 4)

    barrier(CLK_LOCAL_MEM_FENCE);

    if(lx < DM_WGX / 4){

      lclTrg[lx * 4] = lclTrg[lx * 4] + lclTrg[lx * 4 + 2];

    }

#endif

#if DM_OUTPUT <= (DM_WGX / 8)

    barrier(CLK_LOCAL_MEM_FENCE);

    if(lx < DM_WGX / 8){

      lclTrg[lx * 8] = lclTrg[lx * 8] + lclTrg[lx * 8 + 4];

    }

#endif

#if DM_OUTPUT <= (DM_WGX / 16)

    if(lx < DM_WGX / 16){

      lclTrg[lx * 16] = lclTrg[lx * 16] + lclTrg[lx * 16 + 8];

    }

#endif

#if DM_OUTPUT <= (DM_WGX / 32)

    if(lx < DM_WGX / 32){

      lclTrg[lx * 32] = lclTrg[lx * 32] + lclTrg[lx * 32 + 16];

    }

#endif

#if DM_OUTPUT <= (DM_WGX / 64)

    if(lx < DM_WGX / 64){

      lclTrg[lx * 64] = lclTrg[lx * 64] + lclTrg[lx * 64 + 32];

    }

#endif

    if(lx < DM_OUTPUT){

      // first 16 fetch and write to global
      diff[templateNo * (DM_SEARCH_WIDTH * DM_SEARCH_WIDTH * DM_ROTATIONS_NO) + (searchNo + targetStep * DM_TARGETS_PER_LOOP) 
                      * DM_ROTATIONS_NO + lx] = 

          (regionNo < 2 ? 

              diff[templateNo * (DM_SEARCH_WIDTH * DM_SEARCH_WIDTH * DM_ROTATIONS_NO) + (searchNo + targetStep * DM_TARGETS_PER_LOOP) 
                              * DM_ROTATIONS_NO + lx]
                
                  : 0) + lclTrg[lx * (DM_WGX / DM_OUTPUT)];

    }

  }

}






