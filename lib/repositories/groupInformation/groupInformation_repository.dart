import 'dart:io';
import 'dart:typed_data';
import 'package:backend/models/group_members_model.dart';
import 'package:backend/models/guide_model.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:backend/models/packinglist_model.dart';
import 'package:backend/config/adapters.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/models/coupon_model.dart';
import 'package:backend/repositories/groupInformation/base_groupInformation_repository.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

class GroupInformationRepository extends BaseGroupInformationRepository {
  final FirebaseFirestore _firebaseFirestore;
  FirebaseFirestore get firestore => _firebaseFirestore;

  final FirebaseStorage _firebaseStorage;
  Box<GroupInformation>? _cacheBox;

  GroupInformationRepository({
    FirebaseFirestore? firebaseFirestore,
    FirebaseStorage? firebaseStorage,
  })  : _firebaseFirestore = firebaseFirestore ?? FirebaseFirestore.instance,
        _firebaseStorage = firebaseStorage ?? FirebaseStorage.instance;

  Future<void> _openCacheBox() async {
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      if (!kIsWeb) {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        Hive.init(appDocDir.path);
      }

      if (!Hive.isAdapterRegistered(GroupInformationAdapter().typeId)) {
        Hive.registerAdapter(GroupInformationAdapter());
      }
      if (!Hive.isAdapterRegistered(GroupMemberAdapter().typeId)) {
        Hive.registerAdapter(GroupMemberAdapter());
      }
      if (!Hive.isAdapterRegistered(GuideAdapter().typeId)) {
        Hive.registerAdapter(GuideAdapter());
      }

      _cacheBox = await Hive.openBox<GroupInformation>('groupInformationCache');
    }
  }

  @override
  Stream<GroupInformation> getGroupInformation(String groupId) async* {
    await _openCacheBox();

    GroupInformation? cachedData = _cacheBox?.get(groupId);
    if (cachedData != null) yield cachedData;

    Stream<GroupInformation> firestoreStream = _firebaseFirestore
        .collection('groups')
        .doc(groupId)
        .snapshots()
        .map((snapshot) => GroupInformation.fromSnapshot(snapshot));

    await for (var groupInfo in firestoreStream) {
      _cacheBox?.put(groupId, groupInfo);
      yield groupInfo;
    }
  }

  // ----------------- Messages -----------------

  Future<void> createMessage(String groupId, String title, String content,
      String authorId, String authorName,
      {List<Map<String, String>> attachments = const [],
      bool isAdmin = false,
      String? bureauName}) async {
    try {
      final newMessage = {
        'title': title,
        'content': content,
        'authorId': authorId,
        'authorName': authorName,
        'timestamp': FieldValue.serverTimestamp(),
        'attachments': attachments,
        'isRead': isAdmin,
        'isAdmin': isAdmin,
        if (bureauName != null) 'bureauName': bureauName,
      };
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.collection('messages').add(newMessage);
      await groupRef.update({'messagesTotal': FieldValue.increment(1)});
    } catch (e) {
      throw Exception('Failed to create message: $e');
    }
  }

  Future<void> updateMessage(String groupId, String messageId, String title,
      String content, {List<Map<String, String>>? attachments}) async {
    try {
      final messageRef = _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId);
      await messageRef.update({
        'title': title,
        'content': content,
        if (attachments != null) 'attachments': attachments,
      });
    } catch (e) {
      throw Exception('Failed to update message: $e');
    }
  }

  Future<void> deleteMessage(String groupId, String messageId) async {
    try {
      final messageRef = _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId);
      await messageRef.delete();

      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'messagesTotal': FieldValue.increment(-1)});
    } catch (e) {
      throw Exception('Failed to delete message: $e');
    }
  }

  Stream<List<Message>> getMessages(String groupId) {
    return _firebaseFirestore
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Message.fromSnapshot(doc)).toList());
  }

  // ----------------- Admin cross-group inbox -----------------

  Stream<List<GroupMessage>> streamAllGroupMessages(List<String> groupIds) {
    final idSet = groupIds.toSet();
    return _firebaseFirestore.collectionGroup('messages').snapshots().map((snapshot) {
      final messages = snapshot.docs
          .where((doc) => idSet.contains(doc.reference.parent.parent?.id))
          .map((doc) {
        final groupId = doc.reference.parent.parent?.id ?? '';
        final data = doc.data();
        return GroupMessage(
          groupId: groupId,
          messageId: doc.id,
          title: data['title'] as String? ?? '',
          content: data['content'] as String? ?? '',
          authorName: data['authorName'] as String? ?? 'Anonym',
          timestamp: (data['timestamp'] as Timestamp?)?.toDate(),
          isRead: data['isRead'] as bool? ?? true,
          attachments: (data['attachments'] as List<dynamic>?)
                  ?.map((e) => Map<String, String>.from(e as Map))
                  .toList() ??
              [],
        );
      }).toList();
      messages.sort((a, b) {
        if (a.timestamp == null && b.timestamp == null) return 0;
        if (a.timestamp == null) return 1;
        if (b.timestamp == null) return -1;
        return b.timestamp!.compareTo(a.timestamp!);
      });
      return messages;
    });
  }

  Stream<int> streamUnreadMessageCount(List<String> groupIds) {
    final idSet = groupIds.toSet();
    return _firebaseFirestore.collectionGroup('messages').snapshots().map((snapshot) =>
        snapshot.docs.where((doc) {
          if (!idSet.contains(doc.reference.parent.parent?.id)) return false;
          return doc.data()['isRead'] == false;
        }).length);
  }

  Future<void> markMessageAsRead(String groupId, String messageId) async {
    await _firebaseFirestore
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .doc(messageId)
        .update({'isRead': true});
  }

  // ----------------- Comments & replies -----------------

  Future<void> createComment(String groupId, String messageId, String content,
      String authorId, String authorName,
      {bool isAdmin = false, String? bureauName}) async {
    try {
      await _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('comments')
          .add({
        'content': content,
        'authorId': authorId,
        'authorName': authorName,
        'timestamp': FieldValue.serverTimestamp(),
        'isAdmin': isAdmin,
        if (bureauName != null) 'bureauName': bureauName,
      });
    } catch (e) {
      throw Exception('Failed to create comment: $e');
    }
  }

  Stream<List<Comment>> getComments(String groupId, String messageId) {
    return _firebaseFirestore
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .doc(messageId)
        .collection('comments')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Comment.fromSnapshot(doc)).toList());
  }

  Future<void> updateComment(String groupId, String messageId,
      String commentId, String newContent) async {
    try {
      await _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('comments')
          .doc(commentId)
          .update({'content': newContent});
    } catch (e) {
      throw Exception('Failed to update comment: $e');
    }
  }

  Future<void> deleteComment(
      String groupId, String messageId, String commentId) async {
    try {
      await _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('comments')
          .doc(commentId)
          .delete();
    } catch (e) {
      throw Exception('Failed to delete comment: $e');
    }
  }

  // Nested replies to a specific comment.
  Future<void> createReply(String groupId, String messageId, String commentId,
      String content, String authorId, String authorName) async {
    try {
      await _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('comments')
          .doc(commentId)
          .collection('replies')
          .add({
        'content': content,
        'authorId': authorId,
        'authorName': authorName,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to create reply: $e');
    }
  }

  Stream<List<Comment>> getReplies(
      String groupId, String messageId, String commentId) {
    return _firebaseFirestore
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .doc(messageId)
        .collection('comments')
        .doc(commentId)
        .collection('replies')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Comment.fromSnapshot(doc)).toList());
  }

  Future<void> deleteReply(String groupId, String messageId, String commentId,
      String replyId) async {
    try {
      await _firebaseFirestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('comments')
          .doc(commentId)
          .collection('replies')
          .doc(replyId)
          .delete();
    } catch (e) {
      throw Exception('Failed to delete reply: $e');
    }
  }

  // ----------------- Documents -----------------

  Future<String> uploadDocument(String groupId, File file) async {
    try {
      String fileName = DateTime.now().millisecondsSinceEpoch.toString();
      Reference storageRef =
          _firebaseStorage.ref().child('groups/$groupId/documents/$fileName');

      UploadTask uploadTask = storageRef.putFile(file);
      TaskSnapshot snapshot = await uploadTask;

      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      throw Exception('Failed to upload document: $e');
    }
  }

  /// Bytes-based upload (works on web and native alike) used for message
  /// attachments, picked via FilePicker with `withData: true`.
  Future<String> uploadMessageAttachment(
      String groupId, String fileName, Uint8List bytes) async {
    try {
      final storageRef = _firebaseStorage
          .ref()
          .child('groups/$groupId/messageAttachments/'
              '${DateTime.now().millisecondsSinceEpoch}_$fileName');
      final uploadTask = storageRef.putData(bytes);
      final snapshot = await uploadTask;
      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      throw Exception('Failed to upload attachment: $e');
    }
  }

  // ----------------- Members -----------------

  Future<void> addMember(String groupId, GroupMember member) async {
    try {
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'members': FieldValue.arrayUnion([member.toMap()])});
    } catch (e) {
      throw Exception('Failed to add member: $e');
    }
  }

  Future<void> updateMember(String groupId, GroupMember oldMember, GroupMember newMember) async {
    try {
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'members': FieldValue.arrayRemove([oldMember.toMap()])});
      await groupRef.update({'members': FieldValue.arrayUnion([newMember.toMap()])});
    } catch (e) {
      throw Exception('Failed to update member: $e');
    }
  }

  Future<void> deleteMember(String groupId, GroupMember member) async {
    try {
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'members': FieldValue.arrayRemove([member.toMap()])});
    } catch (e) {
      throw Exception('Failed to delete member: $e');
    }
  }

    // ----------------- Guides -----------------

  Future<void> addGuide(String groupId, Guide guide) async {
    try {
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'guides': FieldValue.arrayUnion([guide.toMap()])});
    } catch (e) {
      throw Exception('Failed to add guide: $e');
    }
  }

  Future<void> updateGuide(String groupId, Guide oldGuide, Guide newGuide) async {
    try {
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'guides': FieldValue.arrayRemove([oldGuide.toMap()])});
      await groupRef.update({'guides': FieldValue.arrayUnion([newGuide.toMap()])});
    } catch (e) {
      throw Exception('Failed to update member: $e');
    }
  }

  Future<void> deleteGuide(String groupId, Guide guide) async {
    try {
      final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
      await groupRef.update({'guides': FieldValue.arrayRemove([guide.toMap()])});
    } catch (e) {
      throw Exception('Failed to delete guide: $e');
    }
  }


  Future<List<GroupInformation>> getGroupsByAgency(String agencyCode) async {
    try {
      final querySnapshot = await _firebaseFirestore
          .collection('groups')
          .where('agencyCode', isEqualTo: agencyCode.toUpperCase())
          .get();
      return querySnapshot.docs
          .map((doc) => GroupInformation.fromSnapshot(doc))
          .toList();
    } catch (e) {
      throw Exception('Failed to fetch groups for agency: $e');
    }
  }

  // ----------------- Stats -----------------

  Stream<int> streamUserCount(String agencyCode) {
    return _firebaseFirestore
        .collection('users')
        .where('agencyCode', isEqualTo: agencyCode)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  // ----------------- Packing List -----------------

  Future<void> addPackingListCategory(String groupId, PackinglistCategories category) async {
    final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
    final categoryMap = {
      'categoryName': category.categoryName,
      'items': category.items,
      'iconName': category.iconName,
    };
    await groupRef.update({
      'packinglistCategories': FieldValue.arrayUnion([categoryMap])
    });
  }

  Future<void> updatePackingListCategory(String groupId, PackinglistCategories? oldCategory, PackinglistCategories newCategory) async {
    if (oldCategory == null) return;

    final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
    final groupSnapshot = await groupRef.get();
    final groupData = groupSnapshot.data();

    if (groupData != null && groupData['packinglistCategories'] is List) {
      List<dynamic> categories = List.from(groupData['packinglistCategories']);
      int indexToUpdate = categories.indexWhere(
          (cat) => cat['categoryName'] == oldCategory.categoryName);

      if (indexToUpdate != -1) {
        categories[indexToUpdate] = {
          'categoryName': newCategory.categoryName,
          'items': newCategory.items,
          'iconName': newCategory.iconName,
        };
        await groupRef.update({'packinglistCategories': categories});
      } else {
        await addPackingListCategory(groupId, newCategory);
      }
    }
  }

  Future<void> deletePackingListCategory(String groupId, PackinglistCategories category) async {
    final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
    final groupSnapshot = await groupRef.get();
    final groupData = groupSnapshot.data();

    if (groupData != null && groupData['packinglistCategories'] is List) {
      List<dynamic> categories = List.from(groupData['packinglistCategories']);
      categories.removeWhere((cat) => cat['categoryName'] == category.categoryName);
      await groupRef.update({'packinglistCategories': categories});
    }
  }

  // ----------------- Coupons -----------------

  Future<void> addCoupon(String groupId, Coupon coupon) async {
    final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
    final couponMap = {
      'couponName': coupon.couponName,
      'description': coupon.description,
      'imageURL': coupon.imageURL,
      'link': coupon.link,
    };
    await groupRef.update({
      'coupons': FieldValue.arrayUnion([couponMap])
    });
  }

  Future<void> updateCoupon(String groupId, Coupon oldCoupon, Coupon newCoupon) async {
    final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
    final groupSnapshot = await groupRef.get();
    final groupData = groupSnapshot.data();

    if (groupData != null && groupData['coupons'] is List) {
      List<dynamic> coupons = List.from(groupData['coupons']);
      int indexToUpdate = coupons.indexWhere(
          (c) => c['couponName'] == oldCoupon.couponName);

      if (indexToUpdate != -1) {
        coupons[indexToUpdate] = {
          'couponName': newCoupon.couponName,
          'description': newCoupon.description,
          'imageURL': newCoupon.imageURL,
          'link': newCoupon.link,
        };
        await groupRef.update({'coupons': coupons});
      } else {
        await addCoupon(groupId, newCoupon);
      }
    }
  }

  Future<void> deleteCoupon(String groupId, Coupon coupon) async {
    final groupRef = _firebaseFirestore.collection('groups').doc(groupId);
    final groupSnapshot = await groupRef.get();
    final groupData = groupSnapshot.data();

    if (groupData != null && groupData['coupons'] is List) {
      List<dynamic> coupons = List.from(groupData['coupons']);
      coupons.removeWhere((c) => c['couponName'] == coupon.couponName);
      await groupRef.update({'coupons': coupons});
    }
  }
}
