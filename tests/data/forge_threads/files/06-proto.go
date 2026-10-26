
type ReleaseSourceFileParams struct {
	Lease SourceFileLeaseID `json:"lease"`
}

type SourceFileDescriptor struct {
	FileName        tspath.RootedFilePath `json:"fileName"`
	Path            tspath.PathKey        `json:"path"`
	ContentHash     string                `json:"contentHash"`
	ParseOptionsKey string                `json:"parseOptionsKey"`
	ScriptKind      core.ScriptKind       `json:"scriptKind"`
	NodeID          string                `json:"nodeId"`
}

type RetainSourceFileParams struct {
	File SourceFileDescriptor `json:"file"`
}

type RetainSourceFileResponse struct {
	Lease SourceFileLeaseID `json:"lease"`
}

// GetCachedSourceFileParams address an ordinary cached source file by its complete identity,
// independent of any snapshot or lease.
type GetCachedSourceFileParams struct {
	File SourceFileDescriptor `json:"file"`
}

type GetSymbolOfDeclarationParams struct {
	File  SourceFileDescriptor `json:"file"`
	Index uint32               `json:"index"`
}

type ProfileParams struct {
	Dir string `json:"dir"`
}

type ProfileResult struct {
	File tspath.RootedFilePath `json:"file"`
}

type CreateBuildOrchestratorParams struct {
	RootNames []string                   `json:"rootNames"`
	Cwd       tspath.RootedDirectoryPath `json:"cwd,omitempty"`
	// Only a subset of these options are exposed  the API
	*core.BuildOptions    `json:"buildOptions,omitempty"`
	*core.CompilerOptions `json:"compilerOptions,omitempty"`
}

type CreateBuildOrchestratorResponse struct {
	BuildOrchestratorID BuildOrchestratorID `json:"buildOrchestratorID"`
}

type DisposeBuildOrchestratorParams struct {
	BuildOrchestratorID BuildOrchestratorID `json:"buildOrchestratorID"`
}

type BuildParams struct {
	BuildOrchestratorID BuildOrchestratorID `json:"buildOrchestratorID"`
	Project             string              `json:"project,omitempty"`
}

type BuildResponse struct {
	Status      tsc.ExitStatus        `json:"status"`
	Diagnostics []*DiagnosticResponse `json:"diagnostics,omitempty"`
	Statistics  tsc.Statistics        `json:"statistics"`
}

type CleanBuildParams struct {
	BuildOrchestratorID BuildOrchestratorID `json:"buildOrchestratorID"`
	Project             string              `json:"project,omitempty"`
}

type CleanBuildResponse struct {
	Status       tsc.ExitStatus          `json:"status"`
	Diagnostics  []*DiagnosticResponse   `json:"diagnostics,omitempty"`
	Statistics   tsc.Statistics          `json:"statistics"`
	FilesDeleted []tspath.RootedFilePath `json:"filesDeleted,omitempty"`
}

type BuildOrchestrator struct {
	Build           func(project string) tsc.ExitStatus
	BuildReferences func(project string) tsc.ExitStatus
	CleanReferences func(project string) tsc.ExitStatus
}

type ConfigFileResponse struct {
	FileNames         []tspath.RootedFilePath  `json:"fileNames" nonnil:"true"`
	Options           *core.CompilerOptions    `json:"options" nonnil:"true"`
	BuildOptions      *core.BuildOptions       `json:"buildOptions,omitempty"`
	ProjectReferences []*core.ProjectReference `json:"projectReferences,omitempty"`
	TypeAcquisition   *core.TypeAcquisition    `json:"typeAcquisition,omitempty"`
	CompileOnSave     *bool                    `json:"compileOnSave,omitempty"`
	Raw               any                      `json:"raw,omitempty"`
	Errors            []*DiagnosticResponse    `json:"errors" nonnil:"true"`
}

type ReadConfigFileResponse struct {
	Config any                 `json:"config"`
	Error  *DiagnosticResponse `json:"error,omitempty"`
}

type GetDefaultProjectForFileParams struct {
	Snapshot SnapshotID         `json:"snapshot"`
	File     DocumentIdentifier `json:"file"`
}

type ProjectResponse struct {
	Id project.ID `json:"id"`
	// Handle identifies this project's lifetime across snapshots; Id is its logical name.
	Handle            project.Handle             `json:"handle"`
	ConfigFileName    *tspath.RootedFilePath     `json:"configFileName,omitempty"`
	CurrentDirectory  tspath.RootedDirectoryPath `json:"currentDirectory"`
	Dirty             bool                       `json:"dirty"`
	ParsedCommandLine *ConfigFileResponse        `json:"parsedCommandLine" nonnil:"true"`
}

func NewConfigFileResponse(parsedCommandLine *tsoptions.ParsedCommandLine) *ConfigFileResponse {
	if parsedCommandLine == nil {
		return nil
	}
	compileOnSave := parsedCommandLine.CompileOnSave
	if compileOnSave == nil {
		if rawConfig, ok := parsedCommandLine.Raw.(*collections.OrderedMap[string, any]); ok {
			if value, ok := rawConfig.GetOrZero("compileOnSave").(bool); ok {
				compileOnSave = &value
			}
		}
	}
	compilerOptions := parsedCommandLine.CompilerOptions()
	errors := NewDiagnosticResponses(parsedCommandLine.Errors)
	if errors == nil {
		errors = []*DiagnosticResponse{}
	}
	return &ConfigFileResponse{
		FileNames:         parsedCommandLine.FileNames(),
		Options:           compilerOptions,
		ProjectReferences: parsedCommandLine.ProjectReferences(),
		TypeAcquisition:   parsedCommandLine.TypeAcquisition(),
		CompileOnSave:     compileOnSave,
		Raw:               parsedCommandLine.Raw,
		Errors:            errors,
	}
}

func NewProjectResponse(p *project.Project) *ProjectResponse {
	if p == nil || p.CommandLine == nil {
		panic("NewProjectResponse called with unloaded project")
	}
	var configFileName *tspath.RootedFilePath
	if p.Kind == project.KindConfigured {
		value := p.ConfigFileName()
		configFileName = &value
	}
	return &ProjectResponse{
		Id:                p.ID(),
		Handle:            p.Handle(),
		ConfigFileName:    configFileName,
		CurrentDirectory:  p.CurrentDirectory(),
		Dirty:             p.IsDirty(),
		ParsedCommandLine: NewConfigFileResponse(p.CommandLine),
	}
}

type GetSymbolAtPositionParams struct {
	Snapshot SnapshotID         `json:"snapshot"`
	Project  project.Handle     `json:"project"`
	File     DocumentIdentifier `json:"file"`
	Position uint32             `json:"position"`
}

type GetSymbolsAtPositionsParams struct {
	Snapshot  SnapshotID         `json:"snapshot"`
	Project   project.Handle     `json:"project"`
	File      DocumentIdentifier `json:"file"`
	Positions []uint32           `json:"positions"`
}

type GetSymbolOfSourceFileParams struct {
	Snapshot SnapshotID         `json:"snapshot"`
	Project  project.Handle     `json:"project"`
	File     DocumentIdentifier `json:"file"`
}

type GetSymbolsOfSourceFilesParams struct {
	Snapshot SnapshotID           `json:"snapshot"`
	Project  project.Handle       `json:"project"`
	Files    []DocumentIdentifier `json:"files"`
}

type GetSymbolAtLocationParams struct {
	Snapshot SnapshotID     `json:"snapshot"`
	Project  project.Handle `json:"project"`
	Location NodeHandle     `json:"location"`
}

type GetSymbolsAtLocationsParams struct {
	Snapshot  SnapshotID     `json:"snapshot"`
	Project   project.Handle `json:"project"`
	Locations []NodeHandle   `json:"locations"`
}

type SymbolResponse struct {
	Reference        SymbolReference         `json:"reference"`
	Name             string                  `json:"name"`
	Flags            uint32                  `json:"flags"`
	CheckFlags       uint32                  `json:"checkFlags,omitzero"`
	Declarations     []NodeHandle            `json:"declarations,omitempty"`
	ValueDeclaration NodeHandle              `json:"valueDeclaration,omitempty"`
	Parent           *CompactSymbolReference `json:"parent,omitempty"`
	ExportSymbol     *CompactSymbolReference `json:"exportSymbol,omitempty"`
}

type SymbolOwnerKind uint32

const (
	SymbolOwnerKindFile SymbolOwnerKind = iota
	SymbolOwnerKindSnapshot
)

type SymbolOwner struct {
