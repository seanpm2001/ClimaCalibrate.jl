import TOML, YAML
import JLD2
import Random
using Distributions
import EnsembleKalmanProcesses as EKP
using EnsembleKalmanProcesses.ParameterDistributions
using EnsembleKalmanProcesses.TOMLInterface

export ExperimentConfig, get_prior, initialize, update_ensemble, save_G_ensemble
export path_to_ensemble_member, path_to_model_log, path_to_iteration

"""
    ExperimentConfig(
        n_iterations::Integer,
        ensemble_size::Integer,
        observations,
        noise,
        prior::ParameterDistribution,
        output_dir,
    )
    ExperimentConfig(filepath::AbstractString; kwargs...)

Construct an ExperimentConfig from a given YAML file or directory containing 'experiment_config.yml'.

ExperimentConfig holds the configuration for a calibration experiment.
This can be constructed from a YAML configuration file or directly using individual parameters.
"""
Base.@kwdef struct ExperimentConfig
    n_iterations::Integer
    ensemble_size::Integer
    observations::Any
    noise::Any
    prior::ParameterDistribution
    output_dir::Any
end

function ExperimentConfig(filepath::AbstractString; kwargs...)
    is_yaml_file(f) = isfile(f) && endswith(f, ".yml")
    filepath_extension = joinpath(filepath, "experiment_config.yml")
    if is_yaml_file(filepath)
        config_dict = YAML.load_file(filepath)
        experiment_dir = dirname(filepath)
    elseif isdir(filepath) && is_yaml_file(filepath_extension)
        config_dict = YAML.load_file(filepath_extension)
        experiment_dir = filepath
    else
        error("Invalid experiment configuration filepath: `$filepath`")
    end

    default_output = joinpath(experiment_dir, "output")
    output_dir = get(config_dict, "output_dir", default_output)

    n_iterations = config_dict["n_iterations"]
    ensemble_size = config_dict["ensemble_size"]

    observation_path =
        isabspath(config_dict["observations"]) ? config_dict["observations"] :
        joinpath(experiment_dir, config_dict["observations"])
    observations = JLD2.load_object(observation_path)

    noise_path =
        isabspath(config_dict["noise"]) ? config_dict["noise"] :
        joinpath(experiment_dir, config_dict["noise"])
    noise = JLD2.load_object(noise_path)

    prior_path =
        isabspath(config_dict["prior"]) ? config_dict["prior"] :
        joinpath(experiment_dir, config_dict["prior"])
    prior = get_prior(prior_path)

    return ExperimentConfig(;
        n_iterations,
        ensemble_size,
        observations,
        noise,
        prior,
        output_dir,
        kwargs...,
    )
end

"""
    path_to_ensemble_member(output_dir, iteration, member)

Constructs the path to an ensemble member's directory for a given iteration and member number.
"""
path_to_ensemble_member(output_dir, iteration, member) =
    EKP.TOMLInterface.path_to_ensemble_member(output_dir, iteration, member)

"""
    path_to_model_log(output_dir, iteration, member)

Constructs the path to an ensemble member's forward model log for a given iteration and member number.
"""
path_to_model_log(output_dir, iteration, member) = joinpath(
    path_to_ensemble_member(output_dir, iteration, member),
    "model_log.txt",
)

"""
    path_to_iteration(output_dir, iteration)

Creates the path to the directory for a specific iteration within the specified output directory.
"""
path_to_iteration(output_dir, iteration) =
    joinpath(output_dir, join(["iteration", lpad(iteration, 3, "0")], "_"))

"""
    get_prior(param_dict::AbstractDict; names = nothing)
    get_prior(prior_path::AbstractString; names = nothing)

Constructs the combined prior distribution from a `param_dict` or a TOML configuration file specified by `prior_path`.
If `names` is provided, only those parameters are used.
"""
function get_prior(prior_path::AbstractString; names = nothing)
    param_dict = TOML.parsefile(prior_path)
    return get_prior(param_dict; names)
end

function get_prior(param_dict::AbstractDict; names = nothing)
    names = isnothing(names) ? keys(param_dict) : names
    prior_vec = [get_parameter_distribution(param_dict, n) for n in names]
    prior = combine_distributions(prior_vec)
    return prior
end

"""
    get_param_dict(distribution; names)

Generates a dictionary for parameters based on the specified distribution, assumed to be of floating-point type.
If `names` is not provided, the distribution's names will be used.
"""
function get_param_dict(
    distribution::PD;
    names = distribution.name,
) where {PD <: ParameterDistributions.ParameterDistribution}
    return Dict(
        name => Dict{Any, Any}("type" => "float") for name in distribution.name
    )
end

"""
    save_G_ensemble(config::ExperimentConfig, iteration, G_ensemble)
    save_G_ensemble(output_dir::AbstractString, iteration, G_ensemble)

Saves the ensemble's observation map output to the correct directory based on the provided configuration.
Takes an output directory, either extracted from an ExperimentConfig or passed directly.
"""
save_G_ensemble(config::ExperimentConfig, iteration, G_ensemble) =
    save_G_ensemble(config.output_dir, iteration, G_ensemble)

function save_G_ensemble(output_dir::AbstractString, iteration, G_ensemble)
    iter_path = path_to_iteration(output_dir, iteration)
    JLD2.save_object(joinpath(iter_path, "G_ensemble.jld2"), G_ensemble)
    return G_ensemble
end

function env_experiment_dir(env = ENV)
    key = "CALIBRATION_EXPERIMENT_DIR"
    haskey(env, key) || error(
        "Experiment dir not found in environment. Ensure that env variable \"CALIBRATION_EXPERIMENT_DIR\" is set.",
    )
    return string(env[key])
end

function env_model_interface(env = ENV)
    key = "CALIBRATION_MODEL_INTERFACE"
    haskey(env, key) || error(
        "Model interface file not found in environment. Ensure that env variable \"CALIBRATION_MODEL_INTERFACE\" is set.",
    )
    return string(env[key])
end

function env_iteration(env = ENV)
    key = "CALIBRATION_ITERATION"
    haskey(env, key) || error(
        "Iteration number not found in environment. Ensure that env variable \"CALIBRATION_ITERATION\" is set.",
    )
    return parse(Int, env[key])
end

function env_member_number(env = ENV)
    key = "CALIBRATION_MEMBER_NUMBER"
    haskey(env, key) || error(
        "Member number not found in environment. Ensure that env variable \"CALIBRATION_MEMBER_NUMBER\" is set.",
    )
    return parse(Int, env[key])
end

"""
    initialize(ensemble_size, observations, noise, prior, output_dir; kwargs...)
    initialize(ensemble_size, observations, prior, output_dir; kwargs...)
    initialize(eki::EnsembleKalmanProcess, prior, output_dir)
    initialize(config::ExperimentConfig; kwargs...)
    initialize(filepath::AbstractString; kwargs...)

Initialize the EnsembleKalmanProcess object and parameter files.

Can take in an existing EnsembleKalmanProcess which will be used to generate the
 initial parameter ensemble.

Noise is optional when the observation is an EKP.ObservationSeries.

Additional kwargs may be passed through to the EnsembleKalmanProcess constructor.
"""
initialize(filepath::AbstractString; kwargs...) =
    initialize(ExperimentConfig(filepath); kwargs...)

initialize(config::ExperimentConfig; kwargs...) = initialize(
    config.ensemble_size,
    config.observations,
    config.noise,
    config.prior,
    config.output_dir;
    kwargs...,
)

initialize(
    ensemble_size,
    observations,
    prior,
    output_dir;
    rng_seed = 1234,
    ekp_kwargs...,
) = _initialize(
    ensemble_size,
    observations,
    prior,
    output_dir;
    rng_seed,
    ekp_kwargs...,
)

initialize(
    ensemble_size,
    observations,
    noise,
    prior,
    output_dir;
    rng_seed = 1234,
    ekp_kwargs...,
) = _initialize(
    ensemble_size,
    observations,
    prior,
    output_dir;
    noise,
    rng_seed,
    ekp_kwargs...,
)

function initialize(eki::EKP.EnsembleKalmanProcess, prior, output_dir)
    save_eki_state(eki, output_dir, 0, prior)
    return eki
end

function _initialize(
    ensemble_size,
    observations,
    prior,
    output_dir;
    noise = nothing,
    rng_seed,
    ekp_kwargs...,
)
    Random.seed!(rng_seed)
    rng_ekp = Random.MersenneTwister(rng_seed)
    initial_ensemble =
        EKP.construct_initial_ensemble(rng_ekp, prior, ensemble_size)

    ekp_str_kwargs = Dict([string(k) => v for (k, v) in ekp_kwargs])
    eki_constructor =
        (args...) -> EKP.EnsembleKalmanProcess(
            args...,
            merge(EKP.default_options_dict(EKP.Inversion()), ekp_str_kwargs);
            rng = rng_ekp,
        )

    eki = if isnothing(noise)
        eki_constructor(initial_ensemble, observations, EKP.Inversion())
    else
        eki_constructor(initial_ensemble, observations, noise, EKP.Inversion())
    end

    save_eki_state(eki, output_dir, 0, prior)
    return eki
end

"""
    save_eki_state(eki, output_dir, iteration, prior)

Save EKI state and parameters. Helper function for [`initialize`](@ref) and [`update_ensemble`](@ref)
"""
function save_eki_state(eki, output_dir, iteration, prior)
    param_dict = get_param_dict(prior)
    save_parameter_ensemble(
        EKP.get_u_final(eki),
        prior,
        param_dict,
        output_dir,
        "parameters.toml",
        iteration,
    )

    # Save the EKI object in the 'iteration_xxx' folder
    iter_path = path_to_iteration(output_dir, iteration)
    eki_path = joinpath(iter_path, "eki_file.jld2")
    JLD2.save_object(eki_path, eki)
end

"""
    update_ensemble(output_dir::AbstractString, iteration, prior)
    update_ensemble(config::ExperimentConfig, iteration)
    update_ensemble(config_file::AbstractString, iteration)

Updates the EnsembleKalmanProcess object and saves the parameters for the next iteration.
"""
update_ensemble(config_file::AbstractString, iteration) =
    update_ensemble(ExperimentConfig(config_file), iteration)

update_ensemble(configuration::ExperimentConfig, iteration) =
    update_ensemble(configuration.output_dir, iteration, configuration.prior)

function update_ensemble(output_dir::AbstractString, iteration, prior)
    iter_path = path_to_iteration(output_dir, iteration)
    eki = JLD2.load_object(joinpath(iter_path, "eki_file.jld2"))

    # Load data from the ensemble
    G_ens = JLD2.load_object(joinpath(iter_path, "G_ensemble.jld2"))

    terminate = EKP.update_ensemble!(eki, G_ens)
    save_eki_state(eki, output_dir, iteration + 1, prior)
    return terminate
end
