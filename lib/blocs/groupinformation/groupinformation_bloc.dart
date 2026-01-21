import 'dart:async';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/repositories/groupInformation/groupInformation_repository.dart';
import 'package:bloc/bloc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

part 'groupinformation_event.dart';
part 'groupinformation_state.dart';

class GroupInformationBloc
    extends Bloc<GroupInformationEvent, GroupInformationState> {
  final GroupInformationRepository _groupInformationRepository;
  GroupInformationBloc({
    required GroupInformationRepository groupInformationRepository,
  })  : _groupInformationRepository = groupInformationRepository,
        super(GroupInformationInitial()) {
    on<LoadGroupInformation>(_onLoadGroupInformation);
    on<LoadGroupInformationById>(_onLoadGroupInformationById);
    on<LoadGroupsByAgency>(_onLoadGroupsByAgency);
    on<LogoutEvent>(_onLogout);
    on<ChangeGroupEvent>(_onChangeGroup);
  }

  void _onLoadGroupInformation(
    LoadGroupInformation event,
    Emitter<GroupInformationState> emit,
  ) {
    emit(GroupInformationLoaded(
        groupInformation: event.groupInformation, groupId: ''));
  }

  Future<void> _onLoadGroupInformationById(
    LoadGroupInformationById event,
    Emitter<GroupInformationState> emit,
  ) async {
    emit(GroupInformationLoading());

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('groups')
          .doc(event.groupId)
          .get();

      if (snapshot.exists) {
        final groupInfo = GroupInformation.fromSnapshot(snapshot);
        emit(GroupInformationLoaded(
            groupInformation: groupInfo, groupId: event.groupId));
      } else {
        emit(const GroupInformationError(message: 'Group not found'));
      }
    } catch (error) {
      emit(GroupInformationError(message: 'Failed to load group: $error'));
    }
  }

  Future<void> _onLoadGroupsByAgency(
    LoadGroupsByAgency event,
    Emitter<GroupInformationState> emit,
  ) async {
    emit(GroupInformationLoading());
    try {
      final groups =
          await _groupInformationRepository.getGroupsByAgency(event.agencyCode);
      if (groups.isEmpty) {
        emit(const GroupInformationError(message: 'No groups found for this agency'));
      } else {
        emit(GroupsByAgencyLoaded(groups: groups));
      }
    } catch (e) {
      emit(GroupInformationError(message: 'Failed to search for groups: $e'));
    }
  }

  void _onLogout(
      LogoutEvent event, Emitter<GroupInformationState> emit) {
    emit(GroupInformationInitial());
  }

  void _onChangeGroup(
      ChangeGroupEvent event, Emitter<GroupInformationState> emit) {
    emit(GroupInformationInitial());
  }
}
