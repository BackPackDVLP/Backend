import 'package:backend/models/group_information_model.dart';

abstract class BaseGroupInformationRepository {
  Stream<GroupInformation> getGroupInformation(String groupId);
}
