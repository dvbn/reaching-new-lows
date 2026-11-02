function project_root = setup_paths
% Locate inputs and create output folders relative to this repository.
project_root = fileparts(fileparts(mfilename('fullpath')));
matlab_dir = fullfile(project_root,'matlab');
addpath(matlab_dir,fullfile(matlab_dir,'fct'),fullfile(project_root,'data'),fullfile(project_root,'results'));
cd(matlab_dir);
folders = {'figures/david','figures/results/covid','figures/results/financial','tables','tables/david','matlab/RESULTS/FIGURES','matlab/RESULTS/TABLES','matlab/nnet'};
for j=1:numel(folders)
    folder = fullfile(project_root,folders{j});
    if ~exist(folder,'dir'), mkdir(folder); end
end
end
