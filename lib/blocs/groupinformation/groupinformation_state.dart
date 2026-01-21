part of 'groupinformation_bloc.dart';

abstract class GroupInformationState extends Equatable {
  const GroupInformationState();

  @override
  List<Object> get props => [];
}

class GroupInformationInitial extends GroupInformationState {}

class GroupInformationLoading extends GroupInformationState {}

class GroupInformationLoaded extends GroupInformationState {
  final GroupInformation groupInformation;
  final String groupId;

  const GroupInformationLoaded(
      {required this.groupInformation, required this.groupId});

  @override
  List<Object> get props => [groupInformation, groupId];
}

class GroupsByAgencyLoaded extends GroupInformationState {
  final List<GroupInformation> groups;

  const GroupsByAgencyLoaded({required this.groups});

  @override
  List<Object> get props => [groups];
}

class GroupInformationError extends GroupInformationState {
  final String message;

  const GroupInformationError({required this.message});

  @override
  List<Object> get props => [message];
}