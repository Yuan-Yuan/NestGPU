/*
Query JA

select a.key
from a
where a.attr = (select MAX(b.attr)
                from b
                where a.key = b.key
                )

a is fact table and b is dimension table

*/

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>
#include <cuda.h>
#include <time.h>
#include <algorithm> 
#include <thrust/scan.h>
#include <thrust/execution_policy.h>
#include <thrust/system/cuda/execution_policy.h>

using std::string;

#define MAX_INT 1024*1024*1024
#define BILLION             1000000000

#define CUDACHECK(cmd) do { \
    cudaError_t e = cmd; \
    pid_t pid = getpid();\
    if( e != cudaSuccess ) { \
    printf("Porcess %d Failed: Cuda error %s:%d '%s'\n", \
    pid,__FILE__,__LINE__,cudaGetErrorString(e)); \
    exit(EXIT_FAILURE); \
    } \
} while(0) 

#define NP2(n)              do {                    \
n--;                                            \
n |= n >> 1;                                    \
n |= n >> 2;                                    \
n |= n >> 4;                                    \
n |= n >> 8;                                    \
n |= n >> 16;                                   \
n ++; } while (0) 

template<typename vec_t>
__global__ static void assign_index(vec_t *dim, long  inNum){
    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x * blockDim.x + threadIdx.x;

    for (int i = offset; i<inNum; i += stride)
        dim[i] = i + 1;
}

__global__ static void count_hash_num(int *dim, long  inNum,int *num,int hsize){
    
    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x * blockDim.x + threadIdx.x;

    for(int i=offset;i<inNum;i+=stride){
        int joinKey = ((int *)dim)[i];
        int hKey = joinKey & (hsize-1);
        atomicAdd(&(num[hKey]),1);
    }
}


__global__ static void build_hash_table(int *dim, long inNum, int *psum, int * bucket,int hsize){

    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x * blockDim.x + threadIdx.x;

    for(int i=offset;i<inNum;i+=stride){
        int joinKey = ((int *) dim)[i]; 
        int hKey = joinKey & (hsize-1);
        int pos = atomicAdd(&psum[hKey],1) * 2;
        assert(pos < inNum * 2);
        ((int*)bucket)[pos] = joinKey;
        pos += 1;
        int dimId = i+1;
        ((int*)bucket)[pos] = dimId;
    }

}


__global__ static void count_join_result(int* num, int* psum, int* bucket, int* fact, long inNum, int* count, int * factFilter,int hsize){

    int lcount = 0;
    int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x*blockDim.x + threadIdx.x;

    for(int i=offset;i<inNum;i+=stride){

        int fkey = ((int *)(fact))[i];
        int hkey = fkey &(hsize-1);
        int keyNum = num[hkey];
        int fvalue = 0;

        for(int j=0;j<keyNum;j++){
            int pSum = psum[hkey];
            int dimKey = ((int *)(bucket))[2*j + 2*pSum];

            if(dimKey == fkey){

                int dimId = ((int *)(bucket))[2*j + 2*pSum + 1];
                lcount ++;
                fvalue = dimId;

                break;
            }
        }
        factFilter[i] = fvalue;
    }
    count[offset] = lcount;
}

__global__ static void materialization(int* data, int* psum, long inNum, int * factFilter, int * result)
{
	int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x*blockDim.x + threadIdx.x;
    int localCount = psum[offset];

    for(int i=offset;i<inNum;i+=stride){
    	int dimID = factFilter[i];
    	if(dimID != 0)
    	{    		
    		((int*)result)[localCount] = ((int *)data)[i];
            localCount ++;
    	}
    }
}

__global__ static void right_materialization(int* data, int* psum, long inNum, int * factFilter, int * result)
{
	int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x*blockDim.x + threadIdx.x;
    int localCount = psum[offset];

    for(int i=offset;i<inNum;i+=stride){
    	int dimID = factFilter[i];
    	if(dimID != 0)
    	{    		
    		((int*)result)[localCount] = ((int *)data)[dimID];
            localCount ++;
    	}
    }
}

__global__ static void scanCol(int inNum, int * result1, int * result2, int * filter)
{
	int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x*blockDim.x + threadIdx.x;

    for(int i=offset;i<inNum;i+=stride){
    	if(result1[i] == result2[i])
    	{
    		filter[i] = 1;
    	}
    }
}


__global__ static void compare(int * a, int *b, int size)
{
	int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x*blockDim.x + threadIdx.x;

    for(int i=offset;i<size;i+=stride){
    	if(a[i] != b[i])
    	{
    		printf("error");
    		assert(a[i] == b[i]);
    	}
    }
}

__global__ static void count_hist(int * keys, int size, int * hist,int mask)
{
    int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x * blockDim.x + threadIdx.x;

    for(int i=offset;i<size;i+=stride){
        int hist_value = keys[i] >> mask;
        assert(hist_value < 1024);
        atomicAdd(&hist[hist_value],1);
    }
}

__global__ static void index_scan(int* a_key, int a_size, int * b_key, int * b_offset, int b_size, int * hist, int * prefix, int * factFilter, int* count, int mask){

    int lcount = 0;
    int stride = blockDim.x * gridDim.x;
    long offset = blockIdx.x*blockDim.x + threadIdx.x;

    for(int i=offset;i<a_size;i+=stride){

        int fkey = ((int *)(a_key))[i];
        int hkey = fkey >> mask;
        int keyNum = hist[hkey];
        int pSum = prefix[hkey];
        int fvalue = 0;

        int high = pSum + keyNum;
        int low  = pSum;
        int mid;

        while(low <= high){

			mid = (low + high) / 2;
			int dimKey = ((int *)(b_key))[mid];

            if(dimKey == fkey){

                int dimId = ((int *)(b_offset))[mid];
                lcount ++;
                fvalue = dimId;
                factFilter[i] = fvalue;
                break;
            }
			else if( fkey > dimKey){
				low = mid + 1;
			}
			else if( fkey < dimKey){
				high = mid - 1;
			}
		}		
    }
    count[offset] = lcount;
}

cudaError_t Subquery_proc(int *a_bkey,int * a_ckey,int * a_attr,int a_size,int * b_key,int * b_attr,int b_size, int * c_key, int c_size)
{
    struct timespec start_t, end_t;
    int defaultBlock = 4096;
    double total = 0.0;
    double timeE = 0.0;
    cudaStream_t s; 
    CUDACHECK(cudaStreamCreate(&s)); 

    dim3 grid(defaultBlock);
    dim3 block(256);

    int hsize = b_size;
    NP2(hsize);

    //for GPU-DB like processing
    int *gpu_dim_psum = NULL, *gpu_fact_psum = NULL, *gpu_dim_hashNum = NULL;
    
    int * gpu_count_db = NULL,  * gpu_count_new = NULL, * gpu_resPsum = NULL;
    int * factFilter_db = NULL, * bucket = NULL, * filter = NULL; 
    int * filterResult1 = NULL, * filterResult2 = NULL, * filterResult3 = NULL, * rightResult1 = NULL, * rightResult2 = NULL;
    bool * mapbit =NULL;

    int total_count = 0;
    int all_count = 0;

    clock_gettime(CLOCK_REALTIME,&start_t);
    
    CUDACHECK(cudaMalloc((void **)&gpu_dim_hashNum, hsize * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&gpu_dim_psum, hsize * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&gpu_fact_psum, hsize * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&gpu_count_db, 4096*256*sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&gpu_resPsum, 4096*256*sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&factFilter_db, a_size * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&filter, a_size * sizeof(int)));
	CUDACHECK(cudaMalloc((void **)&gpu_count_new, 4096*256*sizeof(int)));  
    CUDACHECK(cudaMemset(gpu_dim_psum,0, hsize * sizeof(int)));
    CUDACHECK(cudaMemset(gpu_fact_psum,0, hsize * sizeof(int)));

    CUDACHECK(cudaMalloc((void **)&mapbit, a_size * sizeof(bool)));    

    CUDACHECK(cudaMalloc((void **)&bucket, b_size * 2 * sizeof(int))); 

    cudaMemset(mapbit, 0, a_size * sizeof(bool));

    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    printf("init Time: %lf ms hsize %d full block size %d\n", timeE/(1000*1000),hsize,grid.x);

    clock_gettime(CLOCK_REALTIME,&start_t);
    CUDACHECK(cudaMemset(gpu_dim_hashNum,0, hsize * sizeof(int)));  
    CUDACHECK(cudaMemset(factFilter_db,0, a_size * sizeof(int)));    
    CUDACHECK(cudaMemset(gpu_count_db,0, 4096*256 * sizeof(int)));   
    
    count_hash_num<<<4096,256>>>(b_key,b_size,gpu_dim_hashNum,hsize);
    CUDACHECK(cudaDeviceSynchronize());
    thrust::exclusive_scan(thrust::device, gpu_dim_hashNum, gpu_dim_hashNum + hsize, gpu_dim_psum); // in-place scan

    cudaMemcpy(gpu_fact_psum, gpu_dim_psum, hsize * sizeof(int), cudaMemcpyDeviceToDevice);

    build_hash_table<<<4096,256>>>(b_key, b_size,gpu_fact_psum,bucket,hsize);

    CUDACHECK(cudaDeviceSynchronize());
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    printf("build Time: %lf ms \n",  timeE/(1000*1000));
    total += timeE;   

    clock_gettime(CLOCK_REALTIME,&start_t);

    count_join_result<<<4096,256>>>(gpu_dim_hashNum,gpu_dim_psum,bucket,a_bkey,a_size,gpu_count_db,factFilter_db,hsize);

    int tmp1, tmp2;

    CUDACHECK(cudaDeviceSynchronize());

    CUDACHECK(cudaMemcpy(&tmp1,&gpu_count_db[4096*256-1],sizeof(int),cudaMemcpyDeviceToHost));
    thrust::exclusive_scan(thrust::device, gpu_count_db, gpu_count_db + 4096*256, gpu_resPsum); 
    CUDACHECK(cudaMemcpy(&tmp2,&gpu_resPsum[4096*256-1],sizeof(int),cudaMemcpyDeviceToHost));

    int resCount = tmp1 + tmp2;

    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    printf("%d rows probe Time: %lf ms \n", resCount, timeE/(1000*1000));
    total += timeE;   

    clock_gettime(CLOCK_REALTIME,&start_t);

    CUDACHECK(cudaMalloc((void **)&filterResult1, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&filterResult2, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&filterResult3, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&rightResult1, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&rightResult2, resCount * sizeof(int))); 

    //fact table materialization
    materialization<<<4096,256>>>(a_bkey, gpu_resPsum, a_size, factFilter_db, filterResult1);
    materialization<<<4096,256>>>(a_ckey, gpu_resPsum, a_size, factFilter_db, filterResult2);
    materialization<<<4096,256>>>(a_attr, gpu_resPsum, a_size, factFilter_db, filterResult3);
    //dimension table materialization
    right_materialization<<<4096,256>>>(b_key , gpu_resPsum, a_size, factFilter_db, rightResult1);
    right_materialization<<<4096,256>>>(b_attr, gpu_resPsum, a_size, factFilter_db, rightResult2);

    int * a_bkey_new, * a_ckey_new, * a_attr_new;
    a_bkey_new = filterResult1;
    a_ckey_new = filterResult2;
    a_attr_new = filterResult3;

    cudaFree(factFilter_db);

    CUDACHECK(cudaMalloc((void **)&factFilter_db, resCount * sizeof(int))); 
    
    CUDACHECK(cudaMemset(factFilter_db,0, resCount * sizeof(int))); 

    CUDACHECK(cudaDeviceSynchronize());
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    printf("Materialization Intermedia Results Time: %lf ms \n",  timeE/(1000*1000));
    total += timeE;  

    //IN predicate processing

    clock_gettime(CLOCK_REALTIME,&start_t);
    //scan intermedia result for aggregation, like MAX()
    scanCol<<<4096,256>>>(resCount, a_attr_new, rightResult2,factFilter_db);

    CUDACHECK(cudaDeviceSynchronize());
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    printf("scan Time: %lf ms \n", timeE/(1000*1000));
    total += timeE;   

    cudaFree(filterResult1);
    cudaFree(filterResult2);
    cudaFree(filterResult3);
    cudaFree(rightResult1);
    cudaFree(rightResult2);

    printf("GPU-DB like nest Time: %lf ms\n\n", total/(1000*1000));

    //the following is indexing based. main idea is sorting the innermost table 
    //actually, it is another way for join processing
    int * hist_index = NULL, * pre_index  = NULL, * b_offset = NULL;
    total = 0.0;
    int range_num = 1024;

    CUDACHECK(cudaMalloc((void **)&hist_index,  range_num * sizeof(int)));
    CUDACHECK(cudaMalloc((void **)&pre_index,   range_num * sizeof(int)));
    CUDACHECK(cudaMalloc((void **)&b_offset, b_size * sizeof(int))); 
    CUDACHECK(cudaMemset(hist_index, 0, range_num * sizeof(int)));
    //the offsets of tuples in table b
    assign_index<int><<<4096,256>>>(b_offset, b_size);

    clock_gettime(CLOCK_REALTIME,&start_t);

    thrust::sort_by_key(thrust::device, b_key, b_key + b_size, b_offset); //thrust inplace sorting

    CUDACHECK(cudaDeviceSynchronize());
    
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    total += timeE;

    printf("Inner Table Sort Time: %lf ms\n", timeE/(1000*1000));

    clock_gettime(CLOCK_REALTIME, &start_t);

    count_hist<<<4096,256>>>(b_key,b_size,hist_index,10);

    thrust::exclusive_scan(thrust::device, hist_index, hist_index + range_num, pre_index); 

    CUDACHECK(cudaDeviceSynchronize());
    
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    total += timeE;

    printf("Inner Table Build Indexing Time: %lf ms\n", timeE/(1000*1000));

    clock_gettime(CLOCK_REALTIME, &start_t);

    index_scan<<<4096,256>>>(a_bkey, a_size, b_key, b_offset, b_size, hist_index, pre_index, filter, gpu_count_new, 10);

    CUDACHECK(cudaDeviceSynchronize());

    //the rest is just the same with GPU-DB like processing which is unnested.

    CUDACHECK(cudaMemcpy(&tmp1,&gpu_count_new[4096*256-1],sizeof(int),cudaMemcpyDeviceToHost));
    thrust::exclusive_scan(thrust::device, gpu_count_new, gpu_count_new + 4096*256, gpu_resPsum); 
    CUDACHECK(cudaMemcpy(&tmp2,&gpu_resPsum[4096*256-1],sizeof(int),cudaMemcpyDeviceToHost));

    resCount = tmp1 + tmp2;
    
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    total += timeE;

    printf("Index Scan %d rows Time: %lf ms\n", resCount, timeE/(1000*1000));

    clock_gettime(CLOCK_REALTIME, &start_t);

    CUDACHECK(cudaMalloc((void **)&filterResult1, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&filterResult2, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&filterResult3, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&rightResult1, resCount * sizeof(int))); 
    CUDACHECK(cudaMalloc((void **)&rightResult2, resCount * sizeof(int))); 

    materialization<<<4096,256>>>(a_bkey, gpu_resPsum, a_size, filter, filterResult1);
    materialization<<<4096,256>>>(a_ckey, gpu_resPsum, a_size, filter, filterResult2);
    materialization<<<4096,256>>>(a_attr, gpu_resPsum, a_size, filter, filterResult3);
    right_materialization<<<4096,256>>>(b_attr, gpu_resPsum, a_size, filter, rightResult2);

    cudaFree(filter);

    CUDACHECK(cudaMalloc((void **)&filter, resCount * sizeof(int))); 
    
    CUDACHECK(cudaMemset(filter,0, resCount * sizeof(int))); 
    
    scanCol<<<4096,256>>>(resCount, filterResult3, rightResult2,filter);

    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
    total += timeE;

    printf("Index IN Time: %lf ms\n", timeE/(1000*1000));

    printf("Subquery Sort Index Time: %lf ms\n\n", total/(1000*1000));
    cudaError_t cudaStatus = cudaDeviceSynchronize();    

    if(cudaStatus != cudaSuccess)
    {
        fprintf(stderr, "Subquery error\n");
        CUDACHECK(cudaStatus);
    }  

    total += timeE;

    clock_gettime(CLOCK_REALTIME, &start_t);

    CUDACHECK(cudaFree(gpu_dim_hashNum));
    CUDACHECK(cudaFree(gpu_dim_psum));
    CUDACHECK(cudaFree(gpu_fact_psum));
    clock_gettime(CLOCK_REALTIME,&end_t);
    timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;

    printf("local mem free Time: %lf ms\n", timeE/(1000*1000));
    total += timeE;

    cudaStatus = cudaDeviceSynchronize();
    CUDACHECK(cudaStatus);
    return cudaStatus;
}


cudaError_t Preparation(int *a_bkey, int * a_ckey, int * a_attr, int l_size, int * b_key, int * b_attr, int r_size, int * c_key, int c_size, int argc, char* argv[]);

int main(int argc, char* argv[])
{
	int a_size = 4*1024*1024;
	int b_size = 1*1024*1024;

	if(argc >= 2)
	{
		if(atoi(argv[1]) != 0)
		{
			a_size = atoi(argv[1])*1024*1024;
		}
	}

	if(argc >= 3)
	{
		if(atoi(argv[2])!=0)
			b_size = atoi(argv[2])*1024*1024;
	}
	int *a_bkey,*a_ckey,*a_attr; //fact table
	int *b_key,*b_attr; //dimension table
	int *c_key; // for future use
	int c_size = b_size;

	fprintf(stderr,"R relation size %d Rows , S relation size %d \n",a_size,b_size);

	CUDACHECK(cudaHostAlloc((void **)&a_bkey, sizeof(int)*a_size, cudaHostAllocPortable | cudaHostAllocMapped));
	CUDACHECK(cudaHostAlloc((void **)&b_key, sizeof(int)*b_size, cudaHostAllocPortable | cudaHostAllocMapped));
	CUDACHECK(cudaHostAlloc((void **)&a_ckey, sizeof(int)*a_size, cudaHostAllocPortable | cudaHostAllocMapped));
	CUDACHECK(cudaHostAlloc((void **)&b_attr, sizeof(int)*b_size, cudaHostAllocPortable | cudaHostAllocMapped));
	CUDACHECK(cudaHostAlloc((void **)&a_attr, sizeof(int)*a_size, cudaHostAllocPortable | cudaHostAllocMapped));
	CUDACHECK(cudaHostAlloc((void **)&c_key, sizeof(int)*c_size, cudaHostAllocPortable | cudaHostAllocMapped));

	//data generation, TPCH-like
	for (int i = 0; i < b_size; i++)
	{
		b_key[i] = i;	
		b_attr[i] = rand();	
	}

	for (int i = 0; i < c_size; i++)
	{
		c_key[i] = i + 1000000;	
	}

	for (int i = 0; i < a_size; i++)
	{
		int tmp = rand()%b_size;
		if(!tmp)
			tmp ++;
		a_bkey[i] = tmp;
		a_ckey[i] = tmp%c_size + 1000000;
		a_attr[i] = rand();	
	}
	cudaError_t cudaStatus;

	cudaStatus = Preparation(a_bkey, a_ckey, a_attr, a_size,b_key, b_attr, b_size, c_key, c_size, argc, argv);

	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "Subquery failed!\n");
		return 1;
	}

	return 0;
}

cudaError_t Preparation(int *a_bkey, int * a_ckey, int * a_attr, int a_size, int * b_key, int * b_attr, int b_size, int * c_key, int c_size, int argc, char* argv[])
{
	struct timespec start, end;
	struct timespec start_t, end_t;
    cudaError_t cudaStatus;

	int defaultBlock = 4096;	
	int new_size = 0;
	dim3 grid(defaultBlock);
	dim3 block(256);
	cudaStream_t s; 
	CUDACHECK(cudaStreamCreate(&s)); 

	double total = 0.0;

	clock_gettime(CLOCK_REALTIME,&start);
	int * gpu_a_bkey = NULL, * gpu_a_attr = NULL, * gpu_a_ckey = NULL;
	int * gpu_b_key  = NULL, * gpu_b_attr = NULL, * gpu_c_key  = NULL;

	clock_gettime(CLOCK_REALTIME,&start_t);
	int primaryKeySize = a_size * sizeof(int);
	int filterSize     = b_size * sizeof(int);

	CUDACHECK(cudaMalloc((void **)&gpu_a_bkey, primaryKeySize));
	CUDACHECK(cudaMalloc((void **)&gpu_a_ckey, primaryKeySize));
	CUDACHECK(cudaMalloc((void **)&gpu_a_attr, primaryKeySize));
	CUDACHECK(cudaMalloc((void **)&gpu_b_key,  filterSize));
	CUDACHECK(cudaMalloc((void **)&gpu_b_attr, filterSize));
	CUDACHECK(cudaMalloc((void **)&gpu_c_key,  filterSize));    

	clock_gettime(CLOCK_REALTIME,&end_t);
	double timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
	total += timeE;

	printf("init Time: %lf ms\n", timeE/(1000*1000));	

	clock_gettime(CLOCK_REALTIME,&start_t);
	CUDACHECK(cudaMemcpyAsync(gpu_a_bkey, a_bkey, primaryKeySize, cudaMemcpyHostToDevice, s));
	CUDACHECK(cudaMemcpyAsync(gpu_a_ckey, a_ckey, primaryKeySize, cudaMemcpyHostToDevice, s));
	CUDACHECK(cudaMemcpyAsync(gpu_a_attr, a_attr, primaryKeySize, cudaMemcpyHostToDevice, s));
	CUDACHECK(cudaMemcpyAsync(gpu_b_key,  b_key , filterSize, cudaMemcpyHostToDevice, s));
	CUDACHECK(cudaMemcpyAsync(gpu_b_attr, b_attr, filterSize, cudaMemcpyHostToDevice, s));
	CUDACHECK(cudaMemcpyAsync(gpu_c_key,  c_key , filterSize, cudaMemcpyHostToDevice, s));

	clock_gettime(CLOCK_REALTIME,&end_t);
	timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
	total += timeE;

	printf("Host To Device Time: %lf ms\n", timeE/(1000*1000));

 	clock_gettime(CLOCK_REALTIME, &start_t);

	cudaStatus = Subquery_proc(gpu_a_bkey,gpu_a_ckey,gpu_a_attr,a_size,gpu_b_key,gpu_b_attr,b_size,gpu_c_key,c_size);
	
	clock_gettime(CLOCK_REALTIME,&end_t);
	timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
	total += timeE;

	printf("Subquery Time: %lf ms\n", timeE/(1000*1000));
	
	clock_gettime(CLOCK_REALTIME, &start_t);
	CUDACHECK(cudaFree(gpu_a_bkey));
	CUDACHECK(cudaFree(gpu_a_ckey));
	CUDACHECK(cudaFree(gpu_a_attr));
	CUDACHECK(cudaFree(gpu_b_key));
	CUDACHECK(cudaFree(gpu_b_attr));
	CUDACHECK(cudaFree(gpu_c_key));

	clock_gettime(CLOCK_REALTIME,&end_t);
	timeE = (end_t.tv_sec -  start_t.tv_sec)* BILLION + end_t.tv_nsec - start_t.tv_nsec;
	printf("second GPU original memory free Time: %lf ms\n", timeE/(1000*1000));
	total += timeE;

	clock_gettime(CLOCK_REALTIME,&end);
	timeE = (end.tv_sec -  start.tv_sec)* BILLION + end.tv_nsec - start.tv_nsec;
	printf("Whole Processing Time: %lf ms Whole time : %1f ms \n", total/(1000*1000),timeE/(1000*1000));
		
	return cudaDeviceSynchronize();
}