#include "GPU.cuh"

#include <cstdio>
#include <iostream>

#include <GL/glew.h>
#include <curand.h>
#include <cuda_runtime.h>
#include <cuda_gl_interop.h>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/zip_function.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/extrema.h>
#include <thrust/partition.h>
#include <thrust/random.h>

#include "GPU/CUDAError.h"
#include "Graphics/GLError.h"
#include "Utils/Timer.h"

namespace GPU
{
	struct generate_points
	{
		__device__ void operator()(float& x, float& y) const;
	};
	struct is_above_line
	{
		__device__ bool operator()(float x, float y) const;
	};
	struct calc_first_pts
	{
		__device__ void operator()(int head, int key, int index) const;
	};
	struct calc_line_dist
	{
		__device__ float operator()(float x, float y, int key, int hull_count)
			const;
	};
	struct update_heads
	{
		__device__ void operator()(int index) const;
	};
	struct calc_outerior
	{
		__device__ bool operator()(float x, float y, int key, int head,
			int hull_count) const;
	};
	struct is_on_hull
	{
		__device__ bool operator()(int index, int hull_count) const;
	};

	#define PI 3.14159265358f

	static constexpr int CURAND_USAGE_THRESHOLD = 12'000'000;

	curandGenerator_t gen;
	bool is_curand_init;
	thrust::minstd_rand rng;
	thrust::uniform_real_distribution<float> adist(0, 2 * PI);
	thrust::uniform_real_distribution<float> rdist;
	bool is_rng_init;
	int max_n;
	GLuint vbo;
	bool is_host_mem;
	cudaGraphicsResource_t resource;
	void* d_buffer;
	float* h_buffer;

	thrust::device_ptr<float> x, y, dist;
	thrust::device_ptr<int> head, keys, flag, first_pts;

	__constant__ float d_r_min;
	__constant__ float d_r_max;

	__constant__ float* d_x;
	__constant__ float* d_y;
	__constant__ int* d_head;
	__constant__ int* d_first_pts;
	__constant__ int* d_flag;

	__constant__ float d_left_x;
	__constant__ float d_left_y;
	__constant__ float d_right_x;
	__constant__ float d_right_y;

	#define SEND_TO_GPU(symbol, expr) { \
						auto v = (expr); \
						cudaCall(cudaMemcpyToSymbol(symbol, &v, sizeof(v), 0, \
							cudaMemcpyHostToDevice)); }

	__device__ float cross(float ux, float uy, float vx, float vy);
	size_t getCudaMemoryNeeded(int n);

	void init(Config config, const std::vector<int>& ns, GLuint vbo_id)
	{

		int max_n_below_curand_threshold = 0;
		for (int n : ns)
		{
			max_n = std::max(max_n, n);
			if (n < CURAND_USAGE_THRESHOLD)
				max_n_below_curand_threshold = std::max(
					max_n_below_curand_threshold, n);
		}

		float r_min = 0.f, r_max = 1.f;
		switch (config.dataset_type)
		{
			case DatasetType::DISC:
				r_min = 0.f; r_max = 1.f;
				break;
			case DatasetType::RING:
				r_min = 0.9f; r_max = 1.f;
				break;
			case DatasetType::CIRCLE:
				r_min = 1.f; r_max = 1.f;
				break;
			default:
				ASSERT(false);
		}

		if (max_n >= CURAND_USAGE_THRESHOLD)
		{
			is_curand_init = true;
			curandCall(curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_MT19937));
			curandCall(curandSetPseudoRandomGeneratorSeed(gen, config.seed));
			cudaCall(cudaMemcpyToSymbol(d_r_min, &r_min, sizeof(float)));
			cudaCall(cudaMemcpyToSymbol(d_r_max, &r_max, sizeof(float)));
		}

		is_host_mem = config.is_host_mem;
		vbo = vbo_id;

		size_t cuda_needed = getCudaMemoryNeeded(max_n);
		if (!is_host_mem)
		{
			glCall(glBufferData(GL_ARRAY_BUFFER, cuda_needed, NULL, GL_STATIC_DRAW));
			cudaCall(cudaGraphicsGLRegisterBuffer(&resource, vbo,
				cudaGraphicsMapFlagsWriteDiscard));
			if (max_n_below_curand_threshold != 0)
			{
				rng.seed(config.seed);
				rdist = thrust::uniform_real_distribution<float>(r_min, r_max);
				size_t host_bytes = 2 * max_n_below_curand_threshold * sizeof(float);
				cudaCall(cudaMallocHost(&h_buffer, host_bytes));
				is_rng_init = true;
			}
		}
		else
		{
			size_t bytes = 2 * sizeof(float) * max_n;
			glCall(glBufferData(GL_ARRAY_BUFFER, bytes, NULL, GL_STATIC_DRAW));
			cudaCall(cudaMalloc(&d_buffer, cuda_needed));
			cudaCall(cudaMallocHost(&h_buffer, bytes));
		}

		glCall(glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, 0));
	}

	int calculate(int n)
	{
		print("\nRunning GPU for ", n, " points.");

		// Initialize pointers to previously allocated memory.
		size_t cuda_needed = getCudaMemoryNeeded(n);
		if (!is_host_mem)
		{
			size_t size = 0;
			cudaCall(cudaGraphicsMapResources(1, &resource));
			cudaCall(cudaGraphicsResourceGetMappedPointer(&d_buffer, &size, resource));
			ASSERT(size >= cuda_needed);
		}
		cudaCall(cudaMemset(d_buffer, 0, cuda_needed));

		x = thrust::device_ptr<float>(reinterpret_cast<float*>(d_buffer));
		y = thrust::device_ptr<float>(reinterpret_cast<float*>(x.get() + n));
		head = thrust::device_ptr<int>(reinterpret_cast<int*>(y.get() + n));
		keys = thrust::device_ptr<int>(reinterpret_cast<int*>(head.get() + n));
		first_pts = thrust::device_ptr<int>(reinterpret_cast<int*>(keys.get() + n));
		flag = thrust::device_ptr<int>(reinterpret_cast<int*>(first_pts.get() + n));
		dist = thrust::device_ptr<float>(reinterpret_cast<float*>(flag.get() + n));

		SEND_TO_GPU(d_x, x.get());
		SEND_TO_GPU(d_y, y.get());
		SEND_TO_GPU(d_head, head.get());
		SEND_TO_GPU(d_first_pts, first_pts.get());
		SEND_TO_GPU(d_flag, flag.get());

		// Generate points.
		if (n < CURAND_USAGE_THRESHOLD)
		{
			for (int i = 0; i < n; ++i)
			{
				float r = rdist(rng);
				float a = adist(rng);
				h_buffer[i] = r * cos(a);
				h_buffer[i + n] = r * sin(a);
			}
			thrust::copy(h_buffer, h_buffer + 2 * n, x);
		}
		else
		{
			curandCall(curandGenerateUniform(gen, x.get(), 2 * n));
			thrust::for_each_n(thrust::make_zip_iterator(x, y), n,
				thrust::make_zip_function(generate_points{}));
		}

		Timer timer("QuickHull");

		// Find leftmost and rightmost points.
		auto it = thrust::minmax_element(
			thrust::make_zip_iterator(x, y),
			thrust::make_zip_iterator(x + n, y + n));
		auto it_left = it.first.get_iterator_tuple();
		auto it_right = it.second.get_iterator_tuple();
		cudaCall(cudaMemcpyToSymbol(d_left_x, it_left.get<0>().get(),
			sizeof(float), 0, cudaMemcpyDeviceToDevice));
		cudaCall(cudaMemcpyToSymbol(d_left_y, it_left.get<1>().get(),
			sizeof(float), 0, cudaMemcpyDeviceToDevice));
		cudaCall(cudaMemcpyToSymbol(d_right_x, it_right.get<0>().get(),
			sizeof(float), 0, cudaMemcpyDeviceToDevice));
		cudaCall(cudaMemcpyToSymbol(d_right_y, it_right.get<1>().get(),
			sizeof(float), 0, cudaMemcpyDeviceToDevice));
		int left_idx = static_cast<int>(it_left.get<0>() - x);
		int right_idx = static_cast<int>(it_right.get<0>() - x);
		
		// Partition into lower and upper parts.
		auto pivot = thrust::partition(
			thrust::make_zip_iterator(x, y),
			thrust::make_zip_iterator(x + n, y + n),
			thrust::make_zip_function(is_above_line{}));
		int pivot_idx = static_cast<int>(pivot.get_iterator_tuple().get<0>() - x);

		// Sort points in lower and upper parts.
		thrust::sort(thrust::make_zip_iterator(x, y), pivot, thrust::greater<>());
		thrust::sort(pivot, thrust::make_zip_iterator(x + n, y + n));

		// Initialize head.
		head[0] = 1;
		head[pivot.get_iterator_tuple().get<0>() - x] = 1;

		// Prepare variables.
		int hull_count = 0;
		int last_hull_count = 0;
		const int N = n;

		while (hull_count < n)
		{
			// Calculate keys from head.
			auto end = thrust::inclusive_scan(head, head + n, keys);
			hull_count = *(end - 1);
			// Line distance calculation ensured that segment borders will not
			// be selected as the farthest point in the segment (unless there
			// aren't anymore points in the segment). However if there still is
			// some precision-related issue, then this check is a guard from
			// an infinite loop. It should be always false, however I leave it
			// just in case (hull will be correct in respect to float::eps).
			if (hull_count == last_hull_count)
				break;
			last_hull_count = hull_count;
			thrust::for_each_n(keys, n, thrust::placeholders::_1 -= 1);

			// Calculate first_pts from keys and head.
			thrust::counting_iterator<int> iter(0);
			thrust::for_each(
				thrust::make_zip_iterator(head, keys, iter),
				thrust::make_zip_iterator(head + n, keys + n, iter + n),
				thrust::make_zip_function(calc_first_pts{}));

			// Calculate distances from line in segment.
			thrust::transform(
				thrust::make_zip_iterator(x, y, keys,
					thrust::make_constant_iterator(hull_count)),
				thrust::make_zip_iterator(x + n, y + n, keys + n,
					thrust::make_constant_iterator(hull_count)),
				dist,
				thrust::make_zip_function(calc_line_dist{}));

			// Find farthest points in segments.
			auto reduction_border = thrust::reduce_by_key(
				/* reduction keys */
				keys, keys + n,
				/* values input */
				thrust::make_zip_iterator(dist, thrust::make_counting_iterator(0)),
				/* keys output - don't need */
				thrust::make_discard_iterator(),
				/* values output - only care about the index */
				thrust::make_zip_iterator(thrust::make_discard_iterator(), flag),
				/* use maximum to reduce */
				thrust::equal_to<>(), thrust::maximum<>())
			.second.get_iterator_tuple().get<1>();

			// Update heads with farthest points.
			thrust::for_each(flag, reduction_border, update_heads{});

			// Determine outerior points.
			thrust::device_ptr<int> outerior = thrust::device_ptr<int>(
				reinterpret_cast<int*>(dist.get()));
			thrust::constant_iterator<int> citer(hull_count);
			thrust::transform(
				thrust::make_zip_iterator(x, y, keys, head, citer),
				thrust::make_zip_iterator(x + n, y + n, keys + n, head + n, citer),
				outerior,
				thrust::make_zip_function(calc_outerior{}));

			// Discard interior points.
			n = static_cast<int>(
				thrust::stable_partition(
					thrust::make_zip_iterator(x, y, head),
					thrust::make_zip_iterator(x + n, y + n, head + n),
					outerior,
					/* move outerior points to the beginning */
					thrust::placeholders::_1 == 1)
				.get_iterator_tuple().get<0>() - x);
		}

		// Filter potentially at most one point that is one the line between
		// its neightbours.
		if (n > 2)
		{
			thrust::counting_iterator<int> count_iter =
				thrust::make_counting_iterator(0);
			thrust::constant_iterator<int> const_iter = 
				thrust::make_constant_iterator(n);
			hull_count = static_cast<int>(
				thrust::stable_partition(
					thrust::make_zip_iterator(count_iter, const_iter),
					thrust::make_zip_iterator(count_iter + n, const_iter + n),
					thrust::make_zip_function(is_on_hull{}))
				.get_iterator_tuple().get<0>() - count_iter);
		}

		timer.stop();

		// Just release mem by unmapping or copy from GPU to CPU to OpenGL.
		if (!is_host_mem)
		{
			cudaCall(cudaGraphicsUnmapResources(1, &resource));
		}
		else
		{
			size_t bytes = 2 * N * sizeof(float);
			cudaCall(cudaMemcpy(h_buffer, d_buffer, bytes, cudaMemcpyDeviceToHost));
			glCall(glBufferSubData(GL_ARRAY_BUFFER, 0, bytes, h_buffer));
		}

		glCall(glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0,
				(const void*)(N * sizeof(float))));

		return hull_count;
	}

	void terminate()
	{
		if (!is_host_mem)
		{
			cudaCall(cudaGraphicsUnregisterResource(resource));
			if (is_rng_init)
			{
				cudaCall(cudaFreeHost(h_buffer));
			}
		}
		else
		{
			cudaCall(cudaFree(d_buffer));
			cudaCall(cudaFreeHost(h_buffer));
		}

		if (is_curand_init)
		{
			curandCall(curandDestroyGenerator(gen));
		}
	}

	__device__
	void generate_points::operator()(float& x, float& y) const
	{
		float a = x * 2 * PI;
		float r = (d_r_max - d_r_min) * y + d_r_min;
		x = r * cos(a);
		y = r * sin(a);
	}

	__device__
	bool is_above_line::operator()(float x, float y) const
	{
		if (x == d_right_x && y == d_right_y)
			return true;
		// Unfortunately it might happen that even though (x, y) is
		// leftmost point, still cross(...) > 0 (precision problems?).
		if (x == d_left_x && y == d_left_y)
			return false;
		float ux = x - d_right_x, uy = y - d_right_y;
		float vx = d_left_x - d_right_x, vy = d_left_y - d_right_y;
		return cross(ux, uy, vx, vy) > 0;
	}

	__device__
	void calc_first_pts::operator()(int head, int key, int index) const
	{
		if (head == 1)
			d_first_pts[key] = index;
	}

	__device__
	float calc_line_dist::operator()(float x, float y, int key, int hull_count)
		const
	{
		int nxt = key + 1;
		if (nxt == hull_count) nxt = 0;

		int i = d_first_pts[key];
		int j = d_first_pts[nxt];

		// Due to precision problems we have to explicitly ensure that
		// segmenent borders will not be selected as the farthest points in the
		// segment (points stricly inside segment might have distance 0 from
		// the segment line even though they are not on it) becuase it leads
		// to an infinite loop for the main algorithm.
		float x1 = d_x[i], y1 = d_y[i];
		if (x == x1 && y == y1)
			return -1.f;
		float x2 = d_x[j], y2 = d_y[j];
		if (x == x2 && y == y2)
			return -1.f;

		float dx = x2 - x1, dy = y2 - y1;
		float ux = x1 - x, uy = y1 - y;

		return cross(dx, dy, ux, uy);
	}

	__device__
	void update_heads::operator()(int index) const
	{
		d_head[index] = 1;
	}

	__device__
	bool calc_outerior::operator()(float x, float y, int key, int head,
		int hull_count) const
	{
		if (head) return true;

		int nxt = key + 1;
		if (nxt == hull_count) nxt = 0;

		int a = d_first_pts[key];
		int b = d_first_pts[nxt];
		int c = d_flag[key];

		float cx = d_x[c], cy = d_y[c];
		float ux = d_x[a] - cx, uy = d_y[a] - cy;
		x -= cx; y -= cy;
		if (cross(ux, uy, x, y) > 0)
			return true;

		float vx = d_x[b] - cx, vy = d_y[b] - cy;
		return cross(x, y, vx, vy) > 0;
	}

	__device__
	bool is_on_hull::operator()(int index, int hull_count) const
	{
		int prv = index - 1;
		if (prv == -1) prv = hull_count - 1;
		int nxt = index + 1;
		if (nxt == hull_count) nxt = 0;
		
		float px = d_x[prv], py = d_y[prv];
		float ux = d_x[index] - px, uy = d_y[index] - py;
		float vx = d_x[nxt] - px, vy = d_y[nxt] - py;

		return cross(ux, uy, vx, vy) != 0;
	}

	__device__
	float cross(float ux, float uy, float vx, float vy)
	{
		return ux * vy - vx * uy;
	}

	size_t getCudaMemoryNeeded(int n)
	{
		return n * (3 * sizeof(float) + 4 * sizeof(int));
	}

} // namespace GPU
