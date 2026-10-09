part of 'groupinformation_bloc.dart';

abstract class GroupInformationEvent extends Equatable {
  const GroupInformationEvent();

  @override
  List<Object> get props => [];
}

class LoadGroupInformation extends GroupInformationEvent {
  final GroupInformation groupInformation;

  const LoadGroupInformation({required this.groupInformation});

  @override
  List<Object> get props => [groupInformation];
}

class LoadGroupInformationById extends GroupInformationEvent {
  final String groupId;

  const LoadGroupInformationById({required this.groupId});

  @override
  List<Object> get props => [groupId];
}

/// Re-reads the group without going through [GroupInformationLoading], so
/// the screen updates in place instead of flashing a full-screen spinner.
/// For small edits made from the screen itself (e.g. the map switch).
class RefreshGroupInformationById extends GroupInformationEvent {
  final String groupId;

  const RefreshGroupInformationById({required this.groupId});

  @override
  List<Object> get props => [groupId];
}

class LogoutEvent extends GroupInformationEvent {}

class ChangeGroupEvent extends GroupInformationEvent {}

class LoadGroupsByAgency extends GroupInformationEvent {
  final String agencyCode;

  const LoadGroupsByAgency({required this.agencyCode});

  @override
  List<Object> get props => [agencyCode];
}

class UpdateGroupId extends GroupInformationEvent {
  final String groupId;

  const UpdateGroupId({required this.groupId});

  @override
  List<Object> get props => [groupId];
}
