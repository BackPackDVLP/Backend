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
