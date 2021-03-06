
"""
Initializes the edge count matrix M between the blocks.
Calculates the new out, in and total degrees for the updated edge count matrix.
Returns a tuple of M, d_out, d_in, d
"""
function initialize_edge_counts!(
    M::Array{Int64, 2}, g::SimpleWeightedDiGraph, B::Int64, b::Vector{Int64}
    )
    @assert size(M) == (B, B)
    for edge in edges(g)
            M[b[dst(edge)], b[src(edge)]] += weight(edge)
    end
end

function compute_block_neighbors_and_degrees(M::Array{Int64, 2}, block::Int64)
    out_neighbors = findn(M[:, block])
    in_neighbors = findn(M[block, :])
    neighbors = collect(Set(out_neighbors) ∪ Set(in_neighbors))
    k_in = sum(M[block, in_neighbors])
    k_out = sum(M[out_neighbors, block])
    k = k_out + k_in
    neighbors, k_out, k_in, k
end

function compute_block_degrees(M::Array{Int64, 2}, B::Int64)
    # Sum across rows to get the outdegrees for each block
    d_out = reshape(sum(M, 1), B)
    # Sum across cols to get the indegrees for each block
    d_in = reshape(sum(M, 2), B)
    d = d_out + d_in
    return d_out, d_in, d
end

function initialize_edge_counts(
    _::Type{Array{Int64, 2}}, g::SimpleWeightedDiGraph, B::Int64,
    b::Vector{Int64}
    )
    M = zeros(Int64, B, B)
    initialize_edge_counts!(M, g, B, b)
    M
end

function compute_new_matrix(
    M::Array{Int64, 2}, r::Int64, s::Int64, num_blocks::Int64,
    out_block_count_map, in_block_count_map, self_edge_weight::Int64
    )
    M_r_row = copy(M[r, :])
    M_r_col = copy(M[:, r])
    M_s_row = copy(M[s, :])
    M_s_col = copy(M[:, s])

    for (block, out_count) in out_block_count_map
        M_r_col[block] -= out_count
        M_s_col[block] += out_count
        if block == r
            M_r_row[r] -= out_count
            M_r_row[s] += out_count
        elseif block == s
            M_s_row[r] -= out_count
            M_s_row[s] += out_count
        end
    end

    for (block, in_count) in in_block_count_map
        M_r_row[block] -= in_count
        M_s_row[block] += in_count
        if block == r
            M_r_col[r] -= in_count
            M_r_col[s] += in_count
        elseif block == s
            M_s_col[r] -= in_count
            M_s_col[s] += in_count
        end
    end

    M_s_row[r] -= self_edge_weight
    M_s_row[s] += self_edge_weight
    M_s_col[r] -= self_edge_weight
    M_s_col[s] += self_edge_weight

    return M_r_row, M_r_col, M_s_row, M_s_col
end

"""Computes the new rows and cols in `M`, when all nodes from `r` are shifted to
block `s`."""
function compute_new_matrix_agglomerative(
    M::Array{Int64, 2}, r::Int64, s::Int64, num_blocks::Int64
    )

    M_r_row = zeros(Int64, num_blocks)
    M_r_col = zeros(Int64, num_blocks)

    M_s_row = copy(M[s, :])
    M_s_col = copy(M[:, s])

    #TODO: Optimize this
    M_s_row += M[r, :]
    M_s_row[r] = 0
    M_s_row[s] += M[r, r] + M[s, r]

    M_s_col += M[:, r]
    M_s_col[r] = 0
    M_s_col[s] += M[r, r] + M[r, s]

    #TODO : Check self edge case
    return M_r_row, M_r_col, M_s_row, M_s_col
end

function compute_multinomial_probs(
    M::Array{Int64, 2},  degrees::Vector{Int64}, vertex::Int64
    )
    return (M[:, vertex] .+ M[vertex, :]) ./ degrees[vertex]
end

function compute_delta_entropy(
    M::Array{Int64, 2}, r::Int64, s::Int64,
    M_r_col::Vector{Int64}, M_s_col::Vector{Int64}, M_r_row::Vector{Int64},
    M_s_row::Vector{Int64}, d_out::Vector{Int64}, d_in::Vector{Int64},
    d_out_new::Vector{Int64}, d_in_new::Vector{Int64}
    )
    delta = 0.0
    # Sum over col of r in new M
    for t1 in findn(M_r_col)
        # Skip if t1 is r or s to prevent double counting
        if t1 ∈ (r, s)
            continue
        end
        delta -= M_r_col[t1] * log(M_r_col[t1] / d_in_new[t1] / d_out_new[r])
    end
    for t1 in findn(M_s_col)
        if t1 ∈ (r, s)
            continue
        end
        delta -= M_s_col[t1] * log(M_s_col[t1] / d_in_new[t1] / d_out_new[s])
    end
    # Sum over row of r in new M
    for t2 in findn(M_r_row)
        delta -= M_r_row[t2] * log(M_r_row[t2] / d_in_new[r] / d_out_new[t2])
    end
    # Sum over row of s in new M
    for t2 in findn(M_s_row)
        delta -= M_s_row[t2] * log(M_s_row[t2] / d_in_new[s] / d_out_new[t2])
    end
    # Sum over columns in old M
    for t2 in (r, s)
        for t1 in findn(M[:, t2])
            # Skip if t1 is r or s to prevent double counting
            if t1 ∈ (r, s)
                continue
            end
            delta += M[t1, t2] * log(M[t1, t2] / d_in[t1] / d_out[t2])
        end
    end
    # Sum over rows in old M
    for t1 in (r, s)
        for t2 in findn(M[t1, :])
            delta += M[t1, t2] * log(M[t1, t2] / d_in[t1] / d_out[t2])
        end
    end
    #println("Delta: $delta")
    delta
end

function compute_overall_entropy(
        M::Array{Int64, 2}, d_out::Vector{Int64}, d_in::Vector{Int64},
        B::Int64, N::Int64, E::Int64
    )
    rows, cols = findn(M)  # all non-zero entries
    summation_term = 0.0
    for (col, row) in zip(cols, rows)
        summation_term -= M[row, col] * log(M[row, col]/ d_in[row] / d_out[col])
    end
    model_S_term = B^2 / E
    model_S = E * (1 + model_S_term) * log(1 + model_S_term) -
        model_S_term * log(model_S_term) + N*log(B)
    S = model_S + summation_term
    return S
end

function compute_hastings_correction(
        s::Int64, M::Array{Int64, 2}, M_r_row::Vector{Int64},
        M_r_col::Vector{Int64}, B::Int64, d::Vector{Int64}, d_new::Vector{Int64},
        blocks_out_count_map, blocks_in_count_map
    )
    blocks = Set(keys(blocks_out_count_map)) ∪ Set(keys(blocks_in_count_map))
    p_forward = 0.0
    p_backward = 0.0
    for t in blocks
        degree = get(blocks_out_count_map, t, 0) + get(blocks_in_count_map, t, 0)
        p_forward += degree * (M[t, s] + M[s, t] + 1) / (d[t] + B)
        p_backward += degree * (M_r_row[t] + M_r_col[t] + 1) / (d_new[t] + B)
    end
    return p_backward / p_forward
end

function update_partition(
    M::Array{Int64, 2}, r::Int64, s::Int64,
    M_r_col::Vector{Int64}, M_s_col::Vector{Int64},
    M_r_row::Vector{Int64}, M_s_row::Vector{Int64}
    )
    M[:, r] = M_r_col
    M[r, :] = M_r_row
    M[:, s] = M_s_col
    M[s, :] = M_s_row
    #info("Updated partition")
    M
end

function zeros_interblock_edge_matrix(::Type{Array{Int64, 2}}, size::Int64)
    return zeros(Int64, size, size)
end
