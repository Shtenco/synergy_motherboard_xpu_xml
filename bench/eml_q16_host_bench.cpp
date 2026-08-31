#include <array>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#ifdef _OPENMP
#include <omp.h>
#endif
using namespace std;
static constexpr int N=1024, SHIFT=9, MASK=(1<<SHIFT)-1, SCALE=1<<16;
array<int32_t,N+1> E,L;
static bool load_memh(const string&p,array<int32_t,N+1>&t){ifstream f(p);string s;int i=0;while(f>>s&&i<=N){uint32_t x=(uint32_t)stoul(s,nullptr,16);t[i++]=(int32_t)x;}return i==N+1;}
static inline int32_t sat(int64_t x){if(x>INT32_MAX)return INT32_MAX;if(x<INT32_MIN)return INT32_MIN;return (int32_t)x;}
static inline int64_t interp(const array<int32_t,N+1>&t,int32_t raw,int32_t minv){int64_t d=(int64_t)raw-minv;int idx=(int)(d>>SHIFT),fr=(int)(d&MASK);if(idx>=N)return t[N];int64_t y0=t[idx],y1=t[idx+1];return y0+(((y1-y0)*fr)>>SHIFT);}
static inline int32_t eml(int32_t a,int32_t b){return sat(interp(E,a,-4*SCALE)-interp(L,b,SCALE/8));}
int main(int argc,char**argv){if(argc<4){cerr<<"usage: bench exp.memh ln.memh ops\n";return 2;}if(!load_memh(argv[1],E)||!load_memh(argv[2],L)){cerr<<"failed LUT load\n";return 2;}long long ops=stoll(argv[3]);volatile int64_t sink=0;
auto t0=chrono::steady_clock::now();int64_t sum=0;for(long long i=0;i<ops;i++){int32_t a=(int32_t)(-4*SCALE+((uint64_t)i*7919u)%(8u*SCALE+1));int32_t b=(int32_t)(SCALE/8+((uint64_t)i*104729u)%(8u*SCALE+1));sum+=eml(a,b);}sink=sum;auto t1=chrono::steady_clock::now();double sec=chrono::duration<double>(t1-t0).count();cout<<fixed<<setprecision(3)<<"scalar rate="<<ops/sec/1e6<<" M EML/s sec="<<sec<<" checksum="<<sink<<"\n";
#ifdef _OPENMP
int threads=omp_get_max_threads();t0=chrono::steady_clock::now();sum=0;
#pragma omp parallel for reduction(+:sum) schedule(static)
for(long long i=0;i<ops;i++){int32_t a=(int32_t)(-4*SCALE+((uint64_t)i*7919u)%(8u*SCALE+1));int32_t b=(int32_t)(SCALE/8+((uint64_t)i*104729u)%(8u*SCALE+1));sum+=eml(a,b);}sink=sum;t1=chrono::steady_clock::now();sec=chrono::duration<double>(t1-t0).count();cout<<"openmp threads="<<threads<<" rate="<<ops/sec/1e6<<" M EML/s sec="<<sec<<" checksum="<<sink<<"\n";
#endif
cout<<"XPU_V24_HOST_EML_BENCH_PASS\n";}
