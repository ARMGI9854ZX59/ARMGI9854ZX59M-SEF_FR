///////////////////////////////////////////////////////////////////////////////
// PlaceWedgeGoal.uc - PlaceWedgeGoal class
// this goal is given to a Officer to aim at a particular spot and take cover

class SWATTakeCoverAndAimAction extends SWATTakeCoverAction;
///////////////////////////////////////////////////////////////////////////////

import enum ELeanState from Engine.Pawn;
import enum EAICoverLocationType from AICoverFinder;

///////////////////////////////////////////////////////////////////////////////
//
// Variables

var(parameters) Pawn Opponent;
var private AimAtTargetGoal				CurrentAimAtTargetGoal;
var private RotateTowardRotationGoal	CurrentRotateTowardRotationGoal;
var private MoveToOpponentGoal			CurrentMoveToOpponentGoal;
var private AimAroundGoal				CurrentAimAroundGoal;

var config private float				MinCrouchTime;
var config private float				MaxCrouchTime;
var config private float				MinStandTime;
var config private float				MaxStandTime;

var config private float				MinLeanTime;
var config private float				MaxLeanTime;

var config private float				SWATMinTakeCoverAndAttackPercentageChance;
var config private float				SWATMaxTakeCoverAndAttackPercentageChance;

var private Rotator						AimingRotation;
var private ELeanState					AimingLeanState;
var private EAICoverLocationType		AimingCoverLocationType;

var private array<Pawn>					CachedSeenPawns;

var private DistanceToOfficersSensor	DistanceToOfficersSensor;
var private TargetSensor				TargetSensor;
var config private float				MinDistanceToTargetWhileTakingCover;

var private float						MoveBrieflyChance;
var config private float				MoveBrieflyChanceIncrement;
var config private float				AimAroundInnerFovDegrees;
var config private float				AimAroundOuterFovDegrees;
var config private float				AimAroundMinAimTime;
var config private float				AimAroundMaxAimTime;

const kMoveTowardMinTime = 1.0;
const kMoveTowardMaxTime = 2.0;

///////////////////////////////////////////////////////////////////////////////
//
// Selection Heuristic

private function bool CanTakeCoverAndAim()
{
	local Hive HiveMind;

	HiveMind = SwatAIRepository(m_Pawn.Level.AIRepo).GetHive();
	assert(HiveMind != None);
	assert(m_Pawn != None);

	// if we have a weapon, cover is available, the distance is greater than the minimum required
	// between us and the officers, and we can find cover to attack from
	return (ISwatAI(m_Pawn).HasUsableWeapon() && AICoverFinder.IsCoverAvailable() &&
		FindBestCoverToAimingFrom() &&
		!CoverIsInBadPosition());
}

private function bool CoverIsInBadPosition()
{
	local int i;

	for(i=0; i<CachedSeenPawns.Length; ++i)
	{
		// if the cover is too close to anyone we've seen, we can't use it
		if (VSize(CoverResult.CoverLocation - CachedSeenPawns[i].Location) < MinDistanceToTargetWhileTakingCover)
		{
//			log("Cover is too close to a pawn we've seen");
			return true;
		}

		// if the cover is behind anyone we've seen, we can't use it
		if ((Normal(m_Pawn.Location - CachedSeenPawns[i].Location) Dot Normal(CoverResult.CoverLocation - CachedSeenPawns[i].Location)) < 0.0)
		{
//			log("Cover is behind a pawn we've seen");
			return true;
		}
	}

	return false;
}

function float selectionHeuristic( AI_Goal goal )
{
	// if we don't have a pawn yet, set it
	if (m_Pawn == None)
	{
		m_Pawn = AI_CharacterResource(goal.resource).m_pawn;
		assert(m_Pawn != None);
	}

	assert(m_Pawn.IsA('SwatOfficer'));
	AICoverFinder = ISwatAI(m_Pawn).GetCoverFinder();
	assert(AICoverFinder != None);

	if (CanTakeCoverAndAim())
	{
		// return a random value that is above the minimum chance
		return 1.0;
	}
	else
	{
		return 0.0;
	}
}

///////////////////////////////////////////////////////////////////////////////
//
// cleanup

function cleanup()
{
	super.cleanup();

	if (CurrentAimAtTargetGoal != None)
	{
		CurrentAimAtTargetGoal.Release();
		CurrentAimAtTargetGoal = None;
	}

	if (CurrentRotateTowardRotationGoal != None)
	{
		CurrentRotateTowardRotationGoal.Release();
		CurrentRotateTowardRotationGoal = None;
	}

	if (CurrentMoveToOpponentGoal != None)
	{
		CurrentMoveToOpponentGoal.Release();
		CurrentMoveToOpponentGoal = None;
	}

	if (CurrentAimAroundGoal != None)
	{
		CurrentAimAroundGoal.Release();
		CurrentAimAroundGoal = None;
	}

	if (DistanceToOfficersSensor != None)
	{
		DistanceToOfficersSensor.deactivateSensor(self);
		DistanceToOfficersSensor = None;
	}

	// make sure we're not leaning
	StopLeaning();
}

///////////////////////////////////////////////////////////////////////////////
//
// Sub-Behavior Messages

function goalNotAchievedCB( AI_Goal goal, AI_Action child, ACT_ErrorCodes errorCode )
{
	super.goalNotAchievedCB(goal, child, errorCode);

	// if the attacking fails, we fail as well
	InstantFail(errorCode);
}

function goalAchievedCB( AI_Goal goal, AI_Action action )
{
	super.goalAchievedCB(goal, action);

	if (goal == CurrentAimAtTargetGoal)
	{
		instantSucceed();
	}
}

///////////////////////////////////////////////////////////////////////////////
//
// Sensor Messages

private function ActivateTargetSensor()
{
	assert(Opponent != None);

	TargetSensor = TargetSensor(class'AI_Sensor'.static.activateSensor( self, class'TargetSensor', characterResource(), 0, 1000000 ));
	assert(TargetSensor != None);

	TargetSensor.setParameters( Opponent );
}

function OnSensorMessage( AI_Sensor sensor, AI_SensorData value, Object userData )
{
	if (m_Pawn.logTyrion)
		log("TakeCoverAndAttackAim received sensor message from " $ sensor.name $ " value is "$ value.integerData);

	// we only (currently) get messages from a distance sensor
	assert(sensor == DistanceToOfficersSensor);

	if (value.integerData == 1)
	{
		if (m_Pawn.logTyrion)
			log(m_Pawn.Name $ " is too close while " $ Name $ " taking cover.  failing!");

		instantFail(ACT_TOO_CLOSE_TO_OFFICERS);
	}
}

///////////////////////////////////////////////////////////////////////////////
//
// Attacking While Taking Cover

// easier than writing the accessor to commander
private function Pawn GetOpponent()
{
	return ISwatOfficer(m_Pawn).GetOfficerCommanderAction().GetCurrentAssignment();
}

private function StopAiming()
{
	if (CurrentAimAtTargetGoal != None)
	{
		CurrentAimAtTargetGoal.unPostGoal(self);
		CurrentAimAtTargetGoal.Release();
		CurrentAimAtTargetGoal = None;
	}
}

private function Aim(Pawn Opponent, bool bCanSucceedAfterFiring)
{
  if(Opponent == None) {
    return;
  }

	if (CurrentAimAtTargetGoal == None)
	{
		CurrentAimAtTargetGoal = new class'AimAtTargetGoal'(weaponResource(), Opponent);
		assert(CurrentAimAtTargetGoal != None);
		CurrentAimAtTargetGoal.AddRef();
		
		CurrentAimAtTargetGoal.postGoal(self);
	}
}

///////////////////////////////////////////////////////////////////////////////
//
// State Code

private function bool IsRotatedToAimingRotation()
{
	// note, this requires that the pawn's rotation be the aim rotation
	return (m_Pawn.Rotation.Yaw == AimingRotation.Yaw);
}

latent private function RotateToAimingRotation(Pawn Opponent)
{
	assert(CurrentRotateTowardRotationGoal == None);

	if ((Opponent != None) && !IsRotatedToAimingRotation() && !m_Pawn.CanHitTarget(Opponent))
	{
		CurrentRotateTowardRotationGoal = new class'RotateTowardRotationGoal'(movementResource(), achievingGoal.priority, AimingRotation);
		assert(CurrentRotateTowardRotationGoal != None);
		CurrentRotateTowardRotationGoal.AddRef();

		CurrentRotateTowardRotationGoal.postGoal(self);
		WaitForGoal(CurrentRotateTowardRotationGoal);
		CurrentRotateTowardRotationGoal.unPostGoal(self);

		CurrentRotateTowardRotationGoal.Release();
		CurrentRotateTowardRotationGoal = None;
	}
}

private function bool CanLeanAtCoverResult()
{
	assertWithDescription((CoverResult.coverLocationInfo == kAICLI_InCover), "TakeCoverAndAttackAction::CanLeanAtCoverResult - expected coverLocationInfo to be kAICLI_InCover, got " $ CoverResult.coverLocationInfo) ;
	assert(CoverResult.coverSide != kAICLS_NotApplicable);

	if (CoverResult.coverSide == kAICLS_Left)
	{
		// we will check and see if we can lean left
		AimingLeanState = kLeanStateLeft;
	}
	else
	{
		// we will check and see if we can lean right
		AimingLeanState = kLeanStateRight;
	}

	return m_Pawn.CanLean(AimingLeanState, CoverResult.coverLocation, AimingRotation);
}

// tests the current value in the cover result value to determine if a piece of cover is usable
private function bool CanUseCover()
{
	// if the cover result says we have cover and it's low cover,
	// or it's normal cover and we can lean at that point
	if ((CoverResult.coverActor != None) &&
		((CoverResult.coverLocationInfo == kAICLI_InLowCover) ||
		 ((CoverResult.coverLocationInfo == kAICLI_InCover) && CanLeanAtCoverResult())))
	{
		return true;
	}
	else
	{
		return false;
	}
}


// returns true when we find cover and want to use it
protected function bool FindBestCoverToAimingFrom()
{
#if !IG_THIS_IS_SHIPPING_VERSION
    // Used to track down a difficult-to-repro error
    local Actor CoverActor;
#endif

    m_tookCover = false;

	assert(m_Pawn != None);
	assert(SwatCharacterResource(m_Pawn.characterAI).CommonSensorAction != None);
	assert(SwatCharacterResource(m_Pawn.characterAI).CommonSensorAction.GetVisionSensor() != None);

	CachedSeenPawns = SwatCharacterResource(m_Pawn.characterAI).CommonSensorAction.GetVisionSensor().Pawns;
	AimingCoverLocationType = kAICLT_NearestFront;
    CoverResult = AICoverFinder.FindCover(CachedSeenPawns, AimingCoverLocationType);

	if (m_Pawn.logAI)
		log("CoverResult.coverLocationInfo is: "$CoverResult.coverLocationInfo$"  CoverResult.coverActor is: " $CoverResult.coverActor);

	// there's no cover to use
	if (CoverResult.coverActor == None)
		return false;

#if !IG_THIS_IS_SHIPPING_VERSION
    // Used to track down a difficult-to-repro error
    CoverActor = CoverResult.coverActor;
#endif

    if (! CanUseCover())
	{

		AimingCoverLocationType = kAICLT_NearFrontCorner;
		CoverResult = AICoverFinder.FindCoverBehindActor(CachedSeenPawns, CoverResult.coverActor, AimingCoverLocationType);

	    // Unexpected. This happens so infrequently, we should notify in non-
        // shipping builds, but fail gracefully and not hard-assert.
	    if (CoverResult.coverActor == None)
        {
#if !IG_THIS_IS_SHIPPING_VERSION
            ReportUnexpectedFindCoverError(CoverActor);
#endif
		    return false;
        }

        if (! CanUseCover())
		{
			AimingCoverLocationType = kAICLT_FarFrontCorner;
			CoverResult = AICoverFinder.FindCoverBehindActor(CachedSeenPawns, CoverResult.coverActor, AimingCoverLocationType);
			return CanUseCover();
		}
		else
		{
			return true;
		}
	}

	// found cover!
	return true;
}

#if !IG_THIS_IS_SHIPPING_VERSION
protected native function ReportUnexpectedFindCoverError(Actor CoverActor);
#endif

protected latent function TakeCoverAtInitialCoverLocation()
{
    m_tookCover = false;

	assert(m_Pawn != None);
	assert(CoverResult.coverLocationInfo != kAICLI_NotInCover);

	TakeCover();
}

protected latent function TakeCover()
{
//  log("Taking cover at: "$CoverResult.coverLocation);

		Aim(GetOpponent(), false);

	MoveToTakeCover(CoverResult.coverLocation);

	StopAiming();

    // if we're in low cover, we should crouch before rotation
    if (CoverResult.coverLocationInfo == kAICLI_InLowCover)
    {
        m_pawn.ShouldCrouch(true);
    }

	m_tookCover = true;
}


private latent function MoveTowardEnemyBriefly(Pawn Opponent)
{
	CurrentMoveToOpponentGoal = new class'MoveToOpponentGoal'(movementResource(), achievingGoal.priority, Opponent);
	assert(CurrentMoveToOpponentGoal != None);
	CurrentMoveToOpponentGoal.AddRef();

	CurrentMoveToOpponentGoal.SetAcceptNearbyPath(true);
	CurrentMoveToOpponentGoal.SetShouldCrouch(true);
	CurrentMoveToOpponentGoal.SetUseCoveredPaths();

	// post the goal and wait for a period time, then remove the goal.
	CurrentMoveToOpponentGoal.postGoal(self);
	sleep(RandRange(kMoveTowardMinTime, kMoveTowardMaxTime));
	CurrentMoveToOpponentGoal.unPostGoal(self);

	CurrentMoveToOpponentGoal.Release();
	CurrentMoveToOpponentGoal = None;
}

private latent function AimAroundBriefly()
{
	CurrentAimAroundGoal = new class'AimAroundGoal'(weaponResource(), CurrentAimAtTargetGoal.priority - 1);
	assert(CurrentAimAroundGoal != None);
	CurrentAimAroundGoal.AddRef();

	CurrentAimAroundGoal.SetAimWeapon(true);
	CurrentAimAroundGoal.SetAimInnerFovDegrees(AimAroundInnerFovDegrees);
	CurrentAimAroundGoal.SetAimOuterFovDegrees(AimAroundOuterFovDegrees);
	CurrentAimAroundGoal.SetAimAtPointTime(AimAroundMinAimTime, AimAroundMaxAimTime);
	CurrentAimAroundGoal.SetDoOnce(true);

	CurrentAimAroundGoal.postGoal(self);
	WaitForGoal(CurrentAimAroundGoal);

	CurrentAimAroundGoal.unPostGoal(self);
	CurrentAimAroundGoal.Release();
	CurrentAimAroundGoal = None;
}

private latent function AimingWhileCrouchingBehindCover(Pawn Opponent)
{
	// stand up if we can't see our Opponent and we can't hit them
	if (! m_Pawn.CanHit(Opponent))
	{
		// stop crouching
		m_pawn.ShouldCrouch(false);

		// stand up for a bit
		sleep(RandRange(MinStandTime, MaxStandTime));

		// if we can't currently attack our Opponent, aim around or move briefly
		if (! m_Pawn.CanHit(Opponent))
		{
			if (FRand() > MoveBrieflyChance)
			{
				AimAroundBriefly();

				MoveBrieflyChance += MoveBrieflyChanceIncrement;
			}
			else
			{
				MoveTowardEnemyBriefly(Opponent);
			}
		}

		// start crouching again
		m_pawn.ShouldCrouch(true);

		sleep(RandRange(MinCrouchTime, MaxCrouchTime));
	}
}

private function Lean()
{
	if (AimingLeanState == kLeanStateLeft)
	{
		m_Pawn.ShouldLeanRight(false);
		m_Pawn.ShouldLeanLeft(true);
	}
	else
	{
		m_Pawn.ShouldLeanLeft(false);
		m_Pawn.ShouldLeanRight(true);
	}
}

private function StopLeaning()
{
	m_Pawn.ShouldLeanLeft(false);
	m_Pawn.ShouldLeanRight(false);
}

private latent function ReEvaluateCover()
{
	if (FindBestCoverToAimingFrom())
	{
		TakeCover();
	}
	else
	{
		fail(ACT_NO_COVER_FOUND);
	}
}

private latent function AimingWhileLeaningBehindCover(Pawn Opponent)
{
	local bool bReEvaluateCover;

	// lean out if we can't hit our Opponent
	if (! m_Pawn.CanHit(Opponent))
	{
		// start leaning
		Lean();

		// lean for a bit
		sleep(RandRange(MinLeanTime, MaxLeanTime));

		// if we can't hit our current Opponent, we should re-evaluate our cover
		if (! m_Pawn.CanHit(Opponent))
		{
			if (m_Pawn.logAI)
				log("re evaluate cover");

			bReEvaluateCover = true;
		}

		// stop leaning
		StopLeaning();

		if (! m_Pawn.CanHit(Opponent))
		{
			AimAroundBriefly();
		}

		if (bReEvaluateCover)
		{
			ReEvaluateCover();
		}
		else
		{
			// just stand for a bit
			sleep(RandRange(MinStandTime, MaxStandTime));
		}
	}
}

protected latent function AimingFromBehindCover()
{
	local Pawn Opponent;

	// while we can still attack (Opponent is not dead)
	do
	{
		Opponent = GetOpponent();

		Aim(Opponent, true);

		// rotate to the attack orientation
		AimingRotation.Yaw = CoverResult.coverYaw;
		RotateToAimingRotation(Opponent);

		if (CoverResult.coverLocationInfo == kAICLI_InLowCover)
		{
			AimingWhileCrouchingBehindCover(Opponent);
		}
		else
		{
			AimingWhileLeaningBehindCover(Opponent);
		}

		yield();
	} until (! class'Pawn'.static.checkConscious(Opponent));
}

state Running
{
 Begin:
	waitForResourcesAvailable(achievingGoal.priority, achievingGoal.priority);

	// create a sensor so we fail if we get to close to the officers
	DistanceToOfficersSensor = DistanceToOfficersSensor(class'AI_Sensor'.static.activateSensor( self, class'DistanceToOfficersSensor', characterResource(), 0, 1000000 ));
	assert(DistanceToOfficersSensor != None);
	DistanceToOfficersSensor.SetParameters(MinDistanceToTargetWhileTakingCover, true);

	// we must have found cover in our selection heuristic for this to work
	TakeCoverAtInitialCoverLocation();

	// TODO: handle leaning around edges of cover
	// for now we're just doing crouching
	if (m_tookCover)
	{
		// TODO: handle moving to the closest edge of the cover
		// currently we just move to the closest area of cover
		AimingFromBehindCover();

		succeed();
	}
	else
	{
		fail(ACT_NO_COVER_FOUND);
	}
}

///////////////////////////////////////////////////////////////////////////////
defaultproperties
{
	satisfiesGoal = class'SWATTakeCoverAndAimGoal'
}
