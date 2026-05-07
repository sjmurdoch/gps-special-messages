using Test
using Dates

# Include the main module
include(joinpath(@__DIR__, "..", "src", "GPSSpecialMessages.jl"))
using .GPSSpecialMessages

# Include test helpers
include("test_helpers.jl")

@testset "GPSSpecialMessages Tests" begin
    include("test_bit_extraction.jl")
    include("test_lnav_decoder.jl")
    include("test_ascii_decoder.jl")
    include("test_arrow_reader.jl")
    include("test_message_analysis.jl")
    include("test_duckdb_writer.jl")
    include("test_integration.jl")
    include("test_temporal_analysis.jl")
    include("test_ppm_model.jl")
    include("test_statistical_significance.jl")
    include("test_behavioral_changes.jl")
    include("test_oa_parser.jl")
    include("test_convert_nc_to_arrow.jl")
end
