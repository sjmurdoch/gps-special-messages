"""
    GPSSpecialMessages

A Julia module for extracting and decoding GPS LNAV Special Messages
from Arrow files containing packed navigation bits.

Special Messages are found in Subframe 4, Page 17 of the GPS L1 C/A
navigation message. They consist of 176 bits (22 characters) of text
using a GPS-specific character set.

# Quick Start

```julia
using GPSSpecialMessages

# Build the DuckDB database from a directory of Arrow files
process_directory_to_db_parallel("data_arrow/", "messages.duckdb"; verbose=true)
```

# Exports

## Types
- `DecodedSpecialMessage`: Decoded message with metadata
- `FileMetadata`: Metadata from an Arrow file
- `SubframeInfo`: Parsed HOW word information
- `FrameInfo`: Complete frame identification info

## Processing Functions
- `process_directory_to_db_parallel`: Build DuckDB database from a directory of Arrow files
- `extract_all_messages` / `write_batches_to_db`: Two-stage variant of the same pipeline

## Low-level Functions
- `is_special_message_frame`: Check if navbits contain a special message
- `decode_special_message`: Decode 22 bytes to ASCII string
- `extract_special_message_bits`: Extract message bits from frame
- `decode_frame`: Decode a complete special message frame
"""
module GPSSpecialMessages

# Bit extraction utilities
include("bit_extraction.jl")

# LNAV frame parsing
include("lnav_decoder.jl")

# ASCII decoding
include("ascii_decoder.jl")

# Arrow file reading
include("arrow_reader.jl")

# Message analysis utilities
include("message_analysis.jl")

# GPS Operational Advisory (OA) file parsing
include("oa_parser.jl")

# DuckDB database operations
include("duckdb_writer.jl")

# Thread-safe parallel DuckDB processing
include("parallel_processor_threaded.jl")

# Temporal pattern analysis
include("temporal_analysis.jl")

# Satellite-based analysis (PRN-message correlations)
include("satellite_analysis.jl")

# Export types
export DecodedSpecialMessage
export FileMetadata
export SubframeInfo
export FrameInfo
export NavbitRow

# Export DuckDB database functions
export create_database
export process_directory_to_db_parallel  # Handles both parallel and sequential modes
export insert_message!
export insert_messages!
export get_message_count
export get_unique_message_count
export get_duplicate_count
export get_duplicates
export get_duplicate_summary
export get_duplicate_source_pairs
export analyze_duplicate_messages
export create_duplicates_table
export check_and_record_duplicate!
export compute_message_hash
export extract_messages_from_file  # For custom parallel workflows
export MessageBatch  # Container for parallel processing
export extract_all_messages  # Unified extraction function
export write_batches_to_db  # Write batches to DuckDB
export write_batches_to_log  # Write batches to text log
export get_identical_duplicate_count
export get_total_identical_occurrences
export get_identical_duplicates
export get_identical_duplicate_summary
export create_behavioral_tables!
export save_behavioral_metrics!
export save_behavioral_change_points!
export get_behavioral_change_points
export create_nanu_tables!
export save_nanu_records!
export save_nanu_correlations!
export get_nanu_records
export create_sentinel_nanu_table!
export save_sentinel_nanu_correlations!

# Export OA parser types and functions
export NANURecord
export parse_oa_file
export parse_all_oa_files
export nanu_event_timespan
export parse_msg_datetime
export parse_summary_field

# Export message analysis functions
export shannon_entropy
export is_likely_text
export count_printable_chars
export count_null_bytes
export compute_message_stats

# Export utility functions
export is_special_message_frame
export decode_special_message
export extract_special_message_bits
export decode_frame
export format_message

# Export low-level functions for testing
export extract_bits
export extract_word
export word_bits
export invert_bits
export parse_how
export get_sv_id
export parse_frame
export decode_gps_char
export DATA_BITS_MASK
export make_datetime

# Export Arrow reading functions
export read_arrow_navbits
export get_file_metadata
export find_arrow_files
export iter_rows
export get_row_count

# Export parity functions
export compute_parity_bits
export check_word_parity
export set_word_parity
export check_message_parity

# Export constants
export SUBFRAME_4
export PAGE_17_SV_ID
export CP437_TO_UNICODE

# Export temporal analysis types and functions
export MessageTransition
export MessageDuration
export DayOfWeekPattern
export TimeOfDayPattern
export PeriodicityResult
export TransitionCorrelation
export BehavioralMetric
export BehavioralChangePoint
export get_message_transitions
export compute_message_durations
export analyze_day_of_week_patterns
export detect_change_points
export get_messages_by_date_range
export get_duration_distribution
export analyze_time_of_day_patterns
export detect_periodic_patterns
export correlate_transitions_across_prns
export cusum_detect
export compute_behavioral_metrics
export detect_behavioral_change_points

# Export satellite analysis types and functions
export PRNMessageStats
export MessageExclusivity
export PRNOverlapResult
export get_messages_by_prn
export get_prn_exclusivity
export analyze_prn_message_overlap
export get_prn_overlap_details
export find_duplicate_timestamps
export compute_message_rarity
export correlate_rarity_with_prn

end # module
