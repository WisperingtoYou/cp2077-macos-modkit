// macOS: CET does not provide exEntitySpawner (the legacy spawn callback is missing from the 2.3.1 Mac binary).
// CET mods that call it (Sit Anywhere, Lean Anywhere, AMM props, Mansion DLC, Flashlight, Inside Metro, XUtils) get
// this script class instead, with the same calls, spawning through Codeware's DynamicEntitySystem.
public abstract class exEntitySpawner {
    public static func Spawn(entityPath: String, worldTransform: WorldTransform, opt appearance: CName, opt recordID: TweakDBID) -> EntityID {
        let spec = new DynamicEntitySpec();
        // The system takes a record or a template, not both; a record carries its own template.
        if TDBID.IsValid(recordID) {
            spec.recordID = recordID;
        } else {
            spec.templatePath = ResRef.FromString(entityPath);
        }
        if IsNameValid(appearance) {
            spec.appearanceName = appearance;
        }
        spec.position = WorldPosition.ToVector4(WorldTransform.GetWorldPosition(worldTransform));
        spec.orientation = WorldTransform.GetOrientation(worldTransform);
        spec.alwaysSpawned = true;
        return GameInstance.GetDynamicEntitySystem().CreateEntity(spec);
    }

    public static func SpawnRecord(recordID: TweakDBID, worldTransform: WorldTransform, opt appearance: CName) -> EntityID {
        return exEntitySpawner.Spawn("", worldTransform, appearance, recordID);
    }

    public static func Despawn(entity: ref<Entity>) {
        if IsDefined(entity) {
            GameInstance.GetDynamicEntitySystem().DeleteEntity(entity.GetEntityID());
        }
    }
}
